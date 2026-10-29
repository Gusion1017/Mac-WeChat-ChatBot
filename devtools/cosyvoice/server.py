#!/usr/bin/env python3
"""CosyVoice3 本地旁路 TTS 服务（FastAPI + uvicorn）。

设计要点
--------
* **预加载**：进程启动后先用后台线程加载模型，`GET /health` 在加载期间返回 503
  `{"ok": false, "loading": true}`，就绪后返回 200。App 启动时轮询该接口即可。
* **常驻内存**：模型只加载一次；每个音色（girl/loli/onee）的 prompt 特征在加载时
  预提取并缓存（等价于上游 `add_zero_shot_spk`），所以单次请求省掉 0.3~1.5s 的
  speech-tokenizer / campplus 前处理。
* **串行合成**：0.5B 模型在单机上并发合成没有收益，用一把全局锁排队，避免内存峰值。
* **输出**：24k mono 16-bit PCM WAV（RIFF），可直接被 AVAudioPlayer / AVAudioFile 读取。
* **日志**：只记录文本长度、音色、耗时、RTF，**不记录请求正文**。上游 cosyvoice 的
  `logging.info('synthesis text ...')` 会被压到 WARNING 级别。

用法
----
    python server.py --host 127.0.0.1 --port 5051 \
        --model-dir ../../_local/cosyvoice/models/Fun-CosyVoice3-0.5B-2512 \
        --refs ../../_local/cosyvoice/voices \
        --venv ../../_local/cosyvoice/venv        # --venv 仅用于日志/自检提示

对外接口见同目录 CONTRACT.md。
"""

import argparse
import io
import json
import logging
import os
import socket
import sys
import threading
import time
import types
import wave
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

VERSION = "1.1.0"  # 1.1.0：/voices 增加 reference_count（音色参考音频条数）
MAX_TEXT_CHARS = 500
MAX_INSTRUCT_CHARS = 200
MIN_SPEED = 0.5
MAX_SPEED = 2.0
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 5051
DEFAULT_MODEL_NAME = "Fun-CosyVoice3-0.5B-2512"
# 内置音色 id；其余（custom-* / 用户新增）builtin=false
BUILTIN_VOICE_IDS = ("girl", "loli", "onee")
# v2 音色布局：`<id>/prompt.wav` 是 App 合并出的合成用 prompt，原始参考片段在 `<id>/refs/` 下。
# 服务端不做运行时音频拼接，只在元数据里统计 reference_count，合成仍然只读 prompt.wav。
REFERENCE_DIR_NAME = "refs"
# references 条目里可接受的音频路径键（`audio`/`audio_path` 二选一，兼容旧写法 `prompt_wav`）
REFERENCE_AUDIO_KEYS = ("audio", "audio_path", "prompt_wav")

# CosyVoice3 的“系统提示”前缀：官方 example.py 里 zero_shot / cross_lingual /
# instruct 三种用法都要求带上它 + <|endofprompt|>，否则质量明显下降。
SYSTEM_PROMPT = "You are a helpful assistant."
END_OF_PROMPT = "<|endofprompt|>"

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LOCAL_DIR = REPO_ROOT / "_local" / "cosyvoice"
DEFAULT_MODEL_DIR = DEFAULT_LOCAL_DIR / "models" / DEFAULT_MODEL_NAME
DEFAULT_VOICES_DIR = DEFAULT_LOCAL_DIR / "voices"
DEFAULT_VENV = DEFAULT_LOCAL_DIR / "venv"

log = logging.getLogger("cosyvoice.server")


# --------------------------------------------------------------------------- #
# 基础工具
# --------------------------------------------------------------------------- #
def _env(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value or default


def setup_logging(level: str) -> None:
    fmt = "%(asctime)s %(levelname)s %(name)s %(message)s"
    logging.basicConfig(level=getattr(logging, level.upper(), logging.INFO),
                        format=fmt, datefmt="%H:%M:%S", stream=sys.stderr)
    # 上游会把待合成文本打到 info 日志里，这里整体压到 WARNING（我们只记长度）。
    logging.getLogger("cosyvoice").setLevel(logging.WARNING)
    logging.getLogger("uvicorn.error").setLevel(logging.INFO)


def memory_rss_mb() -> Optional[float]:
    """当前进程 RSS（MB）。macOS 上 ru_maxrss 单位是字节，Linux 是 KB。"""
    try:
        import resource
        value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        return round(value / (1024 * 1024), 1) if sys.platform == "darwin" else round(value / 1024, 1)
    except Exception:  # pragma: no cover
        return None


def check_port(host: str, port: int) -> Optional[str]:
    """端口是否可绑定；返回错误信息或 None。"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((host, port))
        return None
    except OSError as exc:
        return f"EADDRINUSE {host}:{port} 无法绑定：{exc}"
    finally:
        sock.close()


def read_wav_info(path: Path) -> Tuple[float, int, int]:
    """返回 (时长秒, 采样率, 声道)；读不出来返回 (0,0,0)。"""
    try:
        with wave.open(str(path), "rb") as wav:
            frames, rate = wav.getnframes(), wav.getframerate()
            return (frames / rate if rate else 0.0, rate, wav.getnchannels())
    except Exception:
        return (0.0, 0, 0)


def wav_bytes(samples_int16_bytes: bytes, sample_rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(samples_int16_bytes)
    return buf.getvalue()


def sys_prompt(text: str) -> str:
    """CosyVoice3 需要的前缀：`You are a helpful assistant.<|endofprompt|>` + 文本。"""
    if END_OF_PROMPT in text:
        return text
    return f"{SYSTEM_PROMPT}{END_OF_PROMPT}{text}"


# --------------------------------------------------------------------------- #
# 音色
# --------------------------------------------------------------------------- #
@dataclass
class Voice:
    id: str
    name: str
    description: str
    prompt_wav: Path
    prompt_text: str = ""
    mode: str = "zero_shot"  # zero_shot | cross_lingual
    duration_s: float = 0.0
    sample_rate: int = 0
    channels: int = 0
    cached: bool = False
    # 个人使用标记：用户上传/合成的音色仅供本人使用，服务不提供导出/分发能力。缺省 true。
    personal_use_only: bool = True
    # 内置音色（girl/loli/onee）为 true；custom-* 为 false
    builtin: bool = True
    # 可选来源说明（用户原创/授权自某个 TTS 声线等），仅供元数据展示
    source: str = ""
    # v2：该音色保存的参考音频条数（旧音色/无 references = 1）。仅元数据展示：
    # 合成仍只用合并后的 prompt_wav，服务端不做多条参考音的运行时拼接。
    reference_count: int = 1

    @property
    def effective_prompt_text(self) -> str:
        """喂给 LLM 的 prompt text（带 CosyVoice3 系统前缀）；cross_lingual 为空。"""
        if self.mode == "cross_lingual" or not self.prompt_text.strip():
            return ""
        return sys_prompt(self.prompt_text.strip())

    def to_public(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "description": self.description,
            "mode": self.mode,
            "duration_s": round(self.duration_s, 2),
            # 参考音频条数（v2 元数据；旧音色/无 references = 1）。合成仍只用 prompt_wav。
            "reference_count": max(1, int(self.reference_count or 1)),
            "has_prompt_text": bool(self.prompt_text.strip()),
            # 个人使用 / 来源标记（App 只读展示，服务不提供导出/分发）
            "personal_use_only": bool(self.personal_use_only),
            "builtin": bool(self.builtin),
            "source": self.source,
        }


def _resolve_manifest_path(raw: Any, base_dir: Path) -> Optional[Path]:
    """解析清单里的路径：支持绝对路径与相对 base_dir；空值/非法值返回 None。"""
    if raw is None:
        return None
    value = str(raw).strip()
    if not value:
        return None
    try:
        path = Path(value)
        if not path.is_absolute():
            path = base_dir / path
        return path.resolve()
    except (OSError, RuntimeError, ValueError):
        return None


def _is_relative_to(path: Path, directory: Path) -> bool:
    """path 是否位于 directory 之内（两者的 resolve 结果）。"""
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def _reference_audio_path(ref: Any, voices_root: Path, voice_id: str, index: int) -> Optional[Path]:
    """取一条 references 条目的有效音频路径；无效（缺失/越界/不存在）返回 None。"""
    if not isinstance(ref, dict):
        log.warning("音色 %s 的第 %d 条参考音频不是对象（跳过）", voice_id, index)
        return None
    raw = next((ref[key] for key in REFERENCE_AUDIO_KEYS if ref.get(key)), None)
    if raw is None:
        log.warning("音色 %s 的第 %d 条参考音频缺少路径（audio/audio_path，跳过）", voice_id, index)
        return None
    path = _resolve_manifest_path(raw, voices_root)
    if path is None:
        log.warning("音色 %s 的第 %d 条参考音频路径无效：%r（跳过）", voice_id, index, raw)
        return None
    if not _is_relative_to(path, voices_root):
        log.warning("音色 %s 的第 %d 条参考音频不在 voices 目录内：%s（跳过）", voice_id, index, path)
        return None
    if not path.is_file():
        log.warning("音色 %s 的第 %d 条参考音频不存在：%s（跳过）", voice_id, index, path)
        return None
    return path


def _manifest_reference_count(refs: Any, voices_root: Path, voice_id: str) -> int:
    """voices.json 条目的参考音频条数：无 references / 全部无效时按 1 条。"""
    if refs is None:
        return 1
    if not isinstance(refs, list):
        log.warning("音色 %s 的 references 不是数组（按 1 条参考音处理）", voice_id)
        return 1
    valid = 0
    for index, ref in enumerate(refs, 1):
        if _reference_audio_path(ref, voices_root, voice_id, index) is not None:
            valid += 1
    if valid == 0:
        if refs:
            log.warning("音色 %s 的 references 没有有效参考音频（回退为 1 条）", voice_id)
        return 1
    return valid


def _scan_reference_count(voice_dir: Path, voices_root: Path) -> int:
    """目录扫描兜底：统计 `<id>/refs/ref-*.wav`（文件需存在且仍在 voices 目录内）。"""
    refs_dir = voice_dir / REFERENCE_DIR_NAME
    if not refs_dir.is_dir():
        return 0
    count = 0
    for child in sorted(refs_dir.iterdir()):
        if not child.name.startswith("ref-") or child.suffix.lower() != ".wav":
            continue
        try:
            resolved = child.resolve()
        except (OSError, RuntimeError):
            continue
        if not child.is_file() or not _is_relative_to(resolved, voices_root):
            continue
        count += 1
    return count


def _voice_from_manifest_entry(item: Any, voices_root: Path) -> Optional[Voice]:
    """把一条 voices.json 条目转成 Voice；不可用时记录 warning 并返回 None。"""
    if not isinstance(item, dict):
        log.warning("voices.json 里有非对象条目（跳过）：%r", item)
        return None
    voice_id = str(item.get("id") or "").strip()
    if not voice_id:
        log.warning("voices.json 里有缺少 id 的条目（跳过）")
        return None
    has_references = isinstance(item.get("references"), list) and bool(item["references"])
    wav = _resolve_manifest_path(item.get("prompt_wav"), voices_root)
    if wav is None or not wav.is_file():
        if has_references:
            # 有 references 但合成用的合并 prompt 缺失：宁可跳过，也不要拿错误的单片段 prompt 合成。
            log.warning("音色 %s 有 references 但合并 prompt.wav 缺失：%s（跳过该音色）",
                        voice_id, item.get("prompt_wav") or "<未填写>")
        else:
            log.warning("音色 %s 的参考音不存在：%s（跳过）", voice_id,
                        item.get("prompt_wav") or "<未填写>")
        return None
    duration, rate, channels = read_wav_info(wav)
    return Voice(
        id=voice_id,
        name=str(item.get("name") or voice_id),
        description=str(item.get("description") or ""),
        prompt_wav=wav,
        prompt_text=str(item.get("prompt_text") or ""),
        mode=str(item.get("mode") or ("zero_shot" if item.get("prompt_text") else "cross_lingual")),
        duration_s=duration,
        sample_rate=rate,
        channels=channels,
        # 缺省：personal_use_only=true；builtin 仅 girl/loli/onee
        personal_use_only=bool(item.get("personal_use_only", True)),
        builtin=bool(item.get("builtin", voice_id in BUILTIN_VOICE_IDS)),
        source=str(item.get("source") or ""),
        reference_count=_manifest_reference_count(item.get("references"), voices_root, voice_id),
    )


def load_voices(voices_dir: Path, strict_manifest: bool = False) -> List[Voice]:
    """读取音色。

    优先 `voices.json`（安装脚本/App 生成，字段见 CONTRACT.md），否则扫描子目录：
    每个子目录里必须有 `prompt.wav`；`prompt.txt` 存在则作为参考文本。

    多条参考音频（v2 布局 `<id>/refs/ref-*.wav`）只影响元数据：`Voice.reference_count`
    用于 `/voices` 展示；服务端**不做运行时音频拼接**，合成仍只用合并后的 `prompt.wav`。
    旧条目没有 `references` 时按 1 条处理。

    `strict_manifest=True`（/voices/reload 用）时，manifest 解析失败直接抛错，
    避免把「清单写坏了」静默降级成目录扫描（音色名/描述会丢）；启动加载仍宽松，
    保证服务能起来。
    """
    voices: List[Voice] = []
    voices_root = voices_dir.resolve()
    manifest = voices_root / "voices.json"
    if manifest.is_file():
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
            entries = data.get("voices", data) if isinstance(data, dict) else data
            if not isinstance(entries, list):
                raise ValueError("voices.json 顶层应为数组，或包含 voices 数组的对象")
            for item in entries:
                voice = _voice_from_manifest_entry(item, voices_root)
                if voice is not None:
                    voices.append(voice)
            log.info("从 voices.json 载入 %d 个音色", len(voices))
            return voices
        except Exception as exc:  # noqa: BLE001 - 解析失败按既有策略回退/抛错
            if strict_manifest:
                raise EngineError(f"解析 {manifest} 失败：{exc}") from exc
            log.error("解析 %s 失败（回退到目录扫描）：%s", manifest, exc)

    if not voices_root.is_dir():
        return voices
    for child in sorted(voices_root.iterdir()):
        if not child.is_dir() or child.name.startswith("."):
            continue
        wav = child / "prompt.wav"
        if not wav.is_file():
            continue
        text = ""
        text_file = child / "prompt.txt"
        if text_file.is_file():
            try:
                text = text_file.read_text(encoding="utf-8").strip()
            except OSError as exc:
                log.warning("读取 %s 失败：%s（按无参考文本处理）", text_file, exc)
        duration, rate, channels = read_wav_info(wav)
        voices.append(Voice(
            id=child.name,
            name=child.name,
            description="",
            prompt_wav=wav,
            prompt_text=text,
            mode="zero_shot" if text else "cross_lingual",
            duration_s=duration,
            sample_rate=rate,
            channels=channels,
            personal_use_only=True,
            builtin=child.name in BUILTIN_VOICE_IDS,
            # 目录扫描兜底：refs/ref-*.wav 存在时按实际条数计，否则旧音色 = 1 条
            reference_count=max(1, _scan_reference_count(child, voices_root)),
        ))
    order = {"girl": 0, "loli": 1, "onee": 2}
    voices.sort(key=lambda v: (order.get(v.id, 99), v.id))
    log.info("扫描目录载入 %d 个音色：%s", len(voices), ", ".join(v.id for v in voices))
    return voices


# --------------------------------------------------------------------------- #
# 引擎
# --------------------------------------------------------------------------- #
class EngineError(Exception):
    pass


class Engine:
    """模型生命周期 + 合成。全部状态对 HTTP 层只读。"""

    def __init__(self, model_dir: Path, voices: List[Voice], device: str = "cpu",
                 threads: int = 0, warmup: bool = True, voices_dir: Optional[Path] = None):
        self.model_dir = model_dir
        self.voices = voices
        self.voice_map = {v.id: v for v in voices}
        self.voices_dir = voices_dir
        self._prompt_signatures: Dict[str, tuple] = {}
        self.device_requested = device
        self.threads = threads
        self.warmup = warmup
        self.state = "starting"          # starting | loading | warming | ready | failed
        self.progress = "等待加载"
        self.error: Optional[str] = None
        self.model = None
        self.sample_rate = 24000
        self.device = device
        self.load_s: Optional[float] = None
        self.loaded_at: Optional[float] = None
        self.hybrid = False
        self._orig_token2wav = None
        self.flow_steps = int(os.environ.get("COSYVOICE_FLOW_STEPS", "6") or 6)
        self.lock = threading.Lock()
        self.stats = {"requests": 0, "errors": 0, "last_rtf": None, "last_synth_ms": None}
        self._torch = None

    # -- 加载 ---------------------------------------------------------------
    def start_loading(self) -> None:
        thread = threading.Thread(target=self.load, name="cosyvoice-loader", daemon=True)
        thread.start()

    def load(self) -> None:
        started = time.perf_counter()
        try:
            self.state = "loading"
            self.progress = "导入 torch"
            import torch
            self._torch = torch
            if self.threads > 0:
                torch.set_num_threads(self.threads)
            torch.set_grad_enabled(False)

            if not self.voices:
                # 零音色也允许启动：普通用户安装后 App 内还没有音色，服务仍需 ready
                # 以便 App 在音色管理里写入 prompt.wav 后调用 POST /voices/reload。
                log.warning("当前没有任何音色（%s），服务将以零音色启动；"
                            "请在 App 音色管理中添加后调用 POST /voices/reload", self._voice_dir_hint())

            self.progress = "导入 cosyvoice（约 5~20s）"
            from cosyvoice.cli.cosyvoice import AutoModel

            self.progress = f"加载模型权重 {self.model_dir.name}（约 20~60s）"
            model = AutoModel(model_dir=str(self.model_dir))
            self.model = model
            self.sample_rate = int(getattr(model, "sample_rate", 24000))
            log.info("模型加载完成：sample_rate=%d，耗时 %.1fs", self.sample_rate, time.perf_counter() - started)

            self.progress = "预提取音色 prompt 特征"
            self._prime_voices()
            self.progress = "应用推理设备"
            self._select_device()

            if self.warmup:
                self.state = "warming"
                self.progress = "预热合成"
                self._warmup()

            self.load_s = time.perf_counter() - started
            self.loaded_at = time.time()
            self.state = "ready"
            self.progress = "就绪"
            log.info("引擎就绪：device=%s，音色=%s，加载 %.1fs，RSS %.0fMB",
                     self.device, list(self.voice_map), self.load_s, memory_rss_mb() or 0)
        except Exception as exc:  # noqa: BLE001 - 需要把失败原因透出给 /health
            self.state = "failed"
            self.error = f"{type(exc).__name__}: {exc}"
            self.progress = "加载失败"
            log.exception("模型加载失败")

    def _voice_dir_hint(self) -> str:
        return f"请先运行 scripts/install_cosyvoice.sh 或检查 --refs 目录里的 voices.json/prompt.wav"

    @staticmethod
    def _prompt_signature(voice: Voice) -> tuple:
        """参考音/prompt 文本的指纹：不变则复用已缓存的特征（reload 不重算）。"""
        try:
            stat = voice.prompt_wav.stat()
            size, mtime = stat.st_size, int(stat.st_mtime)
        except OSError:
            size, mtime = 0, 0
        return (str(voice.prompt_wav), size, mtime, voice.mode, voice.effective_prompt_text)

    def _prime_voices(self, voices: Optional[List[Voice]] = None,
                      force: bool = False) -> Tuple[int, int]:
        """提取并缓存每个音色的 prompt 特征（上游 add_zero_shot_spk）。

        返回 (新增提取数, 复用缓存数)。参考音与 prompt 文本未变化的音色直接复用缓存，
        所以 reload 通常只需几十毫秒；只有新增/改动的音色才需要 2~4s 的特征提取。
        """
        target = list(self.voices if voices is None else voices)
        if not target:  # 零音色是合法状态（普通用户刚装完，尚未添加音色）
            return 0, 0
        added = reused = 0
        for voice in target:
            signature = self._prompt_signature(voice)
            if not force and self._prompt_signatures.get(voice.id) == signature:
                voice.cached = True
                reused += 1
                continue
            if voice.duration_s > 30.0:
                # CosyVoice3 speech tokenizer 的硬限制：>30s 的 prompt 无法提取 speech token。
                log.warning("音色 %s 的参考音 %.1fs 超过 CosyVoice3 的 30s 硬上限，"
                            "特征提取会失败；请把参考音裁到 ≤30s", voice.id, voice.duration_s)
            try:
                self.model.add_zero_shot_spk(voice.effective_prompt_text, str(voice.prompt_wav), voice.id)
                voice.cached = True
                self._prompt_signatures[voice.id] = signature
                added += 1
                log.info("已缓存音色 %s（prompt %s，%.1fs，mode=%s%s）",
                         voice.id, voice.prompt_wav.name, voice.duration_s, voice.mode,
                         "" if voice.builtin else "，custom")
            except Exception as exc:  # 单个音色失败不应阻塞整体
                voice.cached = False
                log.warning("音色 %s prompt 特征缓存失败（将退回逐次提取）：%s", voice.id, exc)
        if not any(v.cached for v in target):
            raise EngineError("所有音色的 prompt 特征都无法提取，请检查参考音（需要 16k 以上采样率的 wav）")
        return added, reused

    def reload_voices(self) -> Dict[str, Any]:
        """重读 --refs/voices.json，重建音色表并补齐 prompt 特征缓存；不重载大模型。

        与 /tts 共用 self.lock：reload 期间不会有合成并发（避免 voice_map 与 spk 缓存错位）。
        """
        if self.state != "ready" or self.model is None:
            raise EngineError("model_not_ready")
        if self.voices_dir is None:
            raise EngineError("voices_dir 未配置，无法重载音色清单")
        started = time.perf_counter()
        new_voices = load_voices(self.voices_dir, strict_manifest=True)  # 读盘不持锁
        # 空清单是合法状态（用户删除了最后一个音色）；解析失败才会在上一行抛错
        with self.lock:
            added, reused = self._prime_voices(new_voices)
            old_ids = {v.id for v in self.voices}
            self.voices = new_voices
            self.voice_map = {v.id: v for v in new_voices}
            elapsed_ms = round((time.perf_counter() - started) * 1000, 1)
        new_ids = {v.id for v in new_voices}
        result = {
            "voices": [v.id for v in new_voices],
            "voices_detail": [v.to_public() for v in new_voices],
            "added": added,
            "reused": reused,
            "removed": sorted(old_ids - new_ids),
            "reload_ms": elapsed_ms,
        }
        log.info("音色清单已重载：%d 个（新提取 %d / 复用缓存 %d / 移除 %d），耗时 %.0fms",
                 len(new_voices), added, reused, len(old_ids - new_ids), elapsed_ms)
        return result

    def _select_device(self) -> None:
        """MPS 采用 hybrid：llm+flow 上 GPU，hift 留 CPU。

        原因：hift 内部 `f0_predictor.to(torch.float64)`（MPS 不支持 float64）且
        `torch.stft` 在 MPS 上未实现。llm+flow 是耗时大头，放到 MPS 收益最大。
        """
        torch = self._torch
        requested = self.device_requested
        wants_mps = requested in ("auto", "mps") and bool(getattr(torch.backends, "mps", None)) \
            and torch.backends.mps.is_available()
        if not wants_mps:
            if requested == "mps":
                log.warning("--device mps 但当前 torch 不支持 MPS，回退 CPU")
            self._move_to_cpu()
            return
        try:
            mps, cpu = torch.device("mps"), torch.device("cpu")
            self.model.model.llm.to(mps)
            self.model.model.flow.to(mps)
            self.model.model.hift.to(cpu)
            self._install_hybrid_token2wav()
            self.model.model.device = mps
            self.model.frontend.device = mps
            self.device = "mps"
            self.hybrid = True
            log.info("已切换到 MPS hybrid（llm+flow=MPS，hift=CPU）")
        except Exception as exc:  # noqa: BLE001
            log.warning("切换到 MPS 失败，回退 CPU：%s", exc)
            self._move_to_cpu()

    def _install_hybrid_token2wav(self) -> None:
        """让 token2wav 支持 flow/hift 分属不同设备（原实现假定同一 device）。"""
        from torch.nn import functional as F

        model = self.model
        if self._orig_token2wav is None:
            self._orig_token2wav = model.model.token2wav
        flow_dev = self._torch.device("mps")
        hift_dev = self._torch.device("cpu")

        def token2wav(self_model, token, prompt_token, prompt_feat, embedding, token_offset,
                      uuid, stream=False, finalize=False, speed=1.0):
            tts_mel, _ = self_model.flow.inference(
                token=token.to(flow_dev, dtype=torch.int32),
                token_len=torch.tensor([token.shape[1]], dtype=torch.int32, device=flow_dev),
                prompt_token=prompt_token.to(flow_dev),
                prompt_token_len=torch.tensor([prompt_token.shape[1]], dtype=torch.int32, device=flow_dev),
                prompt_feat=prompt_feat.to(flow_dev),
                prompt_feat_len=torch.tensor([prompt_feat.shape[1]], dtype=torch.int32, device=flow_dev),
                embedding=embedding.to(flow_dev),
                streaming=stream,
                finalize=finalize,
            )
            tts_mel = tts_mel[:, :, token_offset * self_model.flow.token_mel_ratio:]
            if self_model.hift_cache_dict[uuid] is not None:
                cached = self_model.hift_cache_dict[uuid]["mel"]
                tts_mel = torch.concat([cached.to(tts_mel.device), tts_mel], dim=2)
                self_model.hift_cache_dict[uuid]["mel"] = tts_mel
            else:
                self_model.hift_cache_dict[uuid] = {"mel": tts_mel, "speech_offset": 0}
            if speed != 1.0:
                assert token_offset == 0 and finalize is True, \
                    "speed change only support non-stream inference mode"
                tts_mel = F.interpolate(tts_mel, size=int(tts_mel.shape[2] / speed), mode="linear")
            tts_speech, _ = self_model.hift.inference(speech_feat=tts_mel.to(hift_dev), finalize=finalize)
            tts_speech = tts_speech[:, self_model.hift_cache_dict[uuid]["speech_offset"]:]
            self_model.hift_cache_dict[uuid]["speech_offset"] += tts_speech.shape[1]
            return tts_speech

        model.model.token2wav = types.MethodType(token2wav, model.model)

    def _move_to_cpu(self) -> None:
        import torch
        if self._orig_token2wav is not None:
            self.model.model.token2wav = self._orig_token2wav
            self._orig_token2wav = None
        cpu = torch.device("cpu")
        for module in (self.model.model.llm, self.model.model.flow, self.model.model.hift):
            module.to(cpu)
        self.model.model.device = cpu
        self.model.frontend.device = cpu
        self.device = "cpu"
        self.hybrid = False

    def _warmup(self) -> None:
        if not self.voices:
            log.info("零音色，跳过预热合成")
            return
        voice = self.voices[0]
        try:
            self._synth("你好。", voice, 1.0, None, warmup=True)
            log.info("预热完成（device=%s）", self.device)
        except Exception as exc:  # noqa: BLE001
            if self.device == "mps":
                log.warning("MPS 预热失败，回退 CPU 重试：%s", exc)
                self._move_to_cpu()
                self._synth("你好。", voice, 1.0, None, warmup=True)
                log.info("CPU 预热完成（MPS 不可用已回退）")
            else:
                raise

    # -- 合成 ---------------------------------------------------------------
    def _synth(self, text: str, voice: Voice, speed: float, instruct: Optional[str],
               warmup: bool = False) -> Tuple[bytes, int, float]:
        """返回 (int16 PCM bytes, 实际采样率, 耗时秒)。"""
        torch = self._torch
        model = self.model
        prompt_wav = str(voice.prompt_wav)
        kwargs: Dict[str, Any] = {"stream": False, "speed": speed}
        if voice.cached:
            kwargs["zero_shot_spk_id"] = voice.id

        with torch.inference_mode():
            if instruct:
                instruct_text = sys_prompt(instruct.strip())
                gen = model.inference_instruct2(text, instruct_text, prompt_wav, **kwargs)
            elif voice.mode == "cross_lingual" or not voice.effective_prompt_text:
                # cross_lingual 不需要参考文本；CosyVoice3 要求正文带系统前缀
                gen = model.inference_cross_lingual(sys_prompt(text), prompt_wav, **kwargs)
            else:
                gen = model.inference_zero_shot(text, voice.effective_prompt_text, prompt_wav, **kwargs)
                if warmup is False:
                    pass
            started = time.perf_counter()
            chunks = []
            for item in gen:
                speech = item.get("tts_speech")
                if speech is None or speech.numel() == 0:
                    continue
                chunks.append(speech.detach().to("cpu", dtype=torch.float32))
            elapsed = time.perf_counter() - started
            if not chunks:
                raise EngineError("模型没有返回任何音频")

            import numpy as np
            speech = torch.cat(chunks, dim=1).squeeze(0).clamp_(-0.999, 0.999)
            pcm = (speech.numpy() * 32767.0).round().astype(np.int16).tobytes()
            if not pcm:
                raise EngineError("合成结果为空")
            return pcm, self.sample_rate, elapsed

    def synthesize(self, text: str, voice_id: str, speed: float,
                   instruct: Optional[str]) -> Tuple[bytes, int, Dict[str, Any]]:
        if self.state != "ready" or self.model is None:
            raise EngineError("model_not_ready")
        voice = self.voice_map.get(voice_id)
        if voice is None:
            raise EngineError("unknown_voice")
        max_attempts = 2
        last_exc: Optional[Exception] = None
        for attempt in range(max_attempts):
            try:
                with self.lock:
                    pcm, rate, elapsed = self._synth(text, voice, speed, instruct)
                    duration_s = len(pcm) / 2 / rate
                    self.stats["requests"] += 1
                    self.stats["last_rtf"] = round(elapsed / duration_s, 3) if duration_s else None
                    self.stats["last_synth_ms"] = round(elapsed * 1000)
                    info = {"duration_s": round(duration_s, 3), "synth_ms": round(elapsed * 1000),
                            "rtf": self.stats["last_rtf"], "device": self.device,
                            "sample_rate": rate}
                    return pcm, rate, info
            except Exception as exc:  # noqa: BLE001
                last_exc = exc
                if self.device == "mps" and attempt + 1 < max_attempts:
                    log.warning("MPS 合成失败，回退 CPU 重试一次：%s", exc)
                    with self.lock:
                        self._move_to_cpu()
                        self._prime_voices()
                    continue
                break
        self.stats["errors"] += 1
        raise EngineError(str(last_exc) if last_exc else "synthesis_failed")

    # -- 状态 ---------------------------------------------------------------
    def health_payload(self) -> Tuple[int, Dict[str, Any]]:
        base: Dict[str, Any] = {
            "ok": self.state == "ready",
            "ready": self.state == "ready",
            "version": VERSION,
            "model": DEFAULT_MODEL_NAME if not self.model_dir else self.model_dir.name,
            "model_dir": str(self.model_dir),
            "sample_rate": self.sample_rate,
            "voices": [v.id for v in self.voices],
            "voices_detail": [v.to_public() for v in self.voices],
            "device": self.device,
            "hybrid": self.hybrid,
            "flow_steps": self.flow_steps,
            "state": self.state,
            "progress": self.progress,
            "load_seconds": round(self.load_s, 2) if self.load_s else None,
            "memory_rss_mb": memory_rss_mb(),
            "stats": dict(self.stats),
        }
        if self.state == "ready":
            return 200, base
        if self.state == "failed":
            base.update({"error": "model_load_failed", "detail": self.error or "unknown"})
            return 500, base
        base.update({"loading": True, "detail": self.progress})
        return 503, base


# --------------------------------------------------------------------------- #
# HTTP 层
# --------------------------------------------------------------------------- #
def build_app(engine: Engine):
    from fastapi import FastAPI, Request
    from fastapi.exceptions import RequestValidationError
    from fastapi.responses import JSONResponse, Response
    from pydantic import BaseModel, Field

    app = FastAPI(title="CosyVoice3 Sidecar", version=VERSION,
                  docs_url=None, redoc_url=None, openapi_url=None)

    class ApiError(Exception):
        def __init__(self, status: int, code: str, detail: str):
            self.status, self.code, self.detail = status, code, detail

    class TTSRequest(BaseModel):
        text: str = Field(..., description="待合成文本，1~500 字")
        voice_id: str = Field("girl", description="girl|loli|onee")
        speed: float = Field(1.0, description="0.5~2.0")
        instruct: Optional[str] = Field(None, description="可选，自然语言风格指令")

    @app.exception_handler(ApiError)
    async def _api_error_handler(_request: Request, exc: ApiError):
        return JSONResponse(status_code=exc.status,
                            content={"ok": False, "error": exc.code, "detail": exc.detail})

    @app.exception_handler(RequestValidationError)
    async def _validation_handler(_request: Request, exc: RequestValidationError):
        detail = "; ".join(f"{'.'.join(str(x) for x in e.get('loc', []))}: {e.get('msg')}"
                           for e in exc.errors())[:500]
        return JSONResponse(status_code=400,
                            content={"ok": False, "error": "invalid_request", "detail": detail})

    @app.exception_handler(Exception)
    async def _unhandled_handler(_request: Request, exc: Exception):
        log.exception("未处理异常")
        return JSONResponse(status_code=500,
                            content={"ok": False, "error": "internal_error", "detail": str(exc)[:500]})

    @app.get("/")
    def root():
        return {"name": "cosyvoice3-sidecar", "version": VERSION,
                "endpoints": ["/health", "/voices", "/tts"], "docs": "devtools/cosyvoice/CONTRACT.md"}

    @app.get("/health")
    def health():
        status, payload = engine.health_payload()
        return JSONResponse(status_code=status, content=payload)

    @app.get("/voices")
    def voices():
        return {"ok": True, "voices": [v.to_public() for v in engine.voices]}

    @app.post("/voices/reload")
    def reload_voices():
        """重读音色清单（新增/删除自定义音色后调用），不重载大模型。"""
        if engine.state != "ready":
            _, payload = engine.health_payload()
            raise ApiError(503, "not_ready", payload.get("detail") or engine.progress)
        try:
            result = engine.reload_voices()
        except EngineError as exc:
            if str(exc) == "model_not_ready":
                raise ApiError(503, "not_ready", engine.progress)
            log.error("重载音色失败：%s", exc)
            raise ApiError(500, "reload_failed", str(exc)[:500])
        except Exception as exc:  # noqa: BLE001
            log.exception("重载音色异常")
            raise ApiError(500, "reload_failed", str(exc)[:500])
        return {"ok": True, **result}

    @app.post("/tts")
    def tts(req: TTSRequest):
        text = (req.text or "").strip()
        if not text:
            raise ApiError(400, "empty_text", "text 不能为空")
        if len(text) > MAX_TEXT_CHARS:
            raise ApiError(400, "text_too_long",
                           f"text 长度 {len(text)} 超过上限 {MAX_TEXT_CHARS} 字")
        if not engine.voices:
            raise ApiError(400, "no_voices",
                           "尚未添加音色，请先在 App 音色管理中添加")
        voice_id = (req.voice_id or "girl").strip()
        if voice_id not in engine.voice_map:
            raise ApiError(400, "unknown_voice",
                           f"未知音色 {voice_id}，可选：{', '.join(engine.voice_map) or '（无音色）'}")
        try:
            speed = float(req.speed if req.speed is not None else 1.0)
        except (TypeError, ValueError):
            raise ApiError(400, "invalid_speed", "speed 必须是数字")
        if not (MIN_SPEED <= speed <= MAX_SPEED):
            raise ApiError(400, "invalid_speed", f"speed 需在 {MIN_SPEED}~{MAX_SPEED} 之间")
        instruct = (req.instruct or "").strip() or None
        if instruct and len(instruct) > MAX_INSTRUCT_CHARS:
            raise ApiError(400, "instruct_too_long",
                           f"instruct 长度 {len(instruct)} 超过上限 {MAX_INSTRUCT_CHARS} 字")

        if engine.state != "ready":
            _, payload = engine.health_payload()
            raise ApiError(503, "not_ready", payload.get("detail") or engine.progress)

        started = time.perf_counter()
        try:
            pcm, rate, info = engine.synthesize(text, voice_id, speed, instruct)
        except EngineError as exc:
            if str(exc) == "model_not_ready":
                raise ApiError(503, "not_ready", engine.progress)
            if str(exc) == "unknown_voice":
                raise ApiError(400, "unknown_voice", voice_id)
            log.error("合成失败 voice=%s text_len=%d: %s", voice_id, len(text), exc)
            raise ApiError(500, "synthesis_failed", str(exc)[:500])

        data = wav_bytes(pcm, rate)
        total_ms = round((time.perf_counter() - started) * 1000)
        log.info("tts voice=%s text_len=%d speed=%.2f synth_ms=%d total_ms=%d rtf=%s audio_ms=%d",
                 voice_id, len(text), speed, info["synth_ms"], total_ms, info["rtf"],
                 round(info["duration_s"] * 1000))
        headers = {
            "X-CosyVoice-Version": VERSION,
            "X-CosyVoice-Voice": voice_id,
            "X-CosyVoice-Sample-Rate": str(rate),
            "X-CosyVoice-Duration-Ms": str(round(info["duration_s"] * 1000)),
            "X-CosyVoice-Synth-Ms": str(info["synth_ms"]),
            "X-CosyVoice-RTF": str(info["rtf"]),
            "X-CosyVoice-Device": info["device"],
            "Cache-Control": "no-store",
        }
        return Response(content=data, media_type="audio/wav", headers=headers)

    return app


# --------------------------------------------------------------------------- #
# 入口
# --------------------------------------------------------------------------- #
def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="CosyVoice3 本地 TTS sidecar")
    ap.add_argument("--host", default=_env("COSYVOICE_HOST", DEFAULT_HOST))
    ap.add_argument("--port", type=int, default=int(_env("COSYVOICE_PORT", str(DEFAULT_PORT))))
    ap.add_argument("--model-dir", default=_env("COSYVOICE_MODEL_DIR", str(DEFAULT_MODEL_DIR)))
    ap.add_argument("--refs", default=_env("COSYVOICE_REFS", str(DEFAULT_VOICES_DIR)),
                    help="音色目录（voices.json + 各音色 prompt.wav）")
    ap.add_argument("--repo", default=_env("COSYVOICE_REPO", str(DEFAULT_LOCAL_DIR / "repo")),
                    help="CosyVoice 仓库根目录")
    ap.add_argument("--venv", default=_env("COSYVOICE_VENV", str(DEFAULT_VENV)),
                    help="仅用于日志/自检展示")
    ap.add_argument("--device", default=_env("COSYVOICE_DEVICE", "cpu"),
                    choices=["cpu", "mps", "auto"], help="推理设备，默认 cpu；auto/mps 失败自动回退 CPU")
    ap.add_argument("--threads", type=int, default=int(_env("COSYVOICE_THREADS", "0")),
                    help="torch CPU 线程数，0=自动")
    # 实测（M3 Max CPU）：10 步热态 RTF 2.6 / 6 步 1.8 / 4 步 1.5；ASR 复核 4/6/8/10 步文本一致。
    # 默认 6 = 质量优先；COSYVOICE_FLOW_STEPS=4 为速度优先。
    ap.add_argument("--flow-steps", type=int, default=int(_env("COSYVOICE_FLOW_STEPS", "6")),
                    help="flow 采样步数：10=官方默认；6=默认折中；4=速度优先")
    ap.add_argument("--no-warmup", action="store_true", help="跳过首次预热合成")
    ap.add_argument("--log-level", default=_env("COSYVOICE_LOG_LEVEL", "info"),
                    choices=["debug", "info", "warning", "error"])
    ap.add_argument("--access-log", action="store_true", help="打开 uvicorn 访问日志（默认关闭）")
    ap.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    return ap.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    setup_logging(args.log_level)
    # tqdm 进度条会污染 App 采集的日志，统一关掉
    os.environ.setdefault("TQDM_DISABLE", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    if args.device in ("auto", "mps"):
        # MPS 上未实现的算子（如 torch.stft）回退到 CPU 执行，避免直接崩溃
        os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    os.environ["COSYVOICE_FLOW_STEPS"] = str(args.flow_steps)

    repo = Path(args.repo).expanduser().resolve()
    model_dir = Path(args.model_dir).expanduser().resolve()
    voices_dir = Path(args.refs).expanduser().resolve()
    venv_dir = Path(args.venv).expanduser()

    # 把仓库与 third_party/Matcha-TTS 加入 sys.path（官方 example.py 的做法）
    for extra in (repo, repo / "third_party" / "Matcha-TTS"):
        if extra.is_dir() and str(extra) not in sys.path:
            sys.path.insert(0, str(extra))

    log.info("cosyvoice sidecar v%s 启动（pid=%d）", VERSION, os.getpid())
    log.info("  model_dir = %s", model_dir)
    log.info("  voices_dir = %s", voices_dir)
    log.info("  repo      = %s", repo)
    log.info("  venv      = %s", venv_dir)
    log.info("  listen    = http://%s:%d", args.host, args.port)

    # 前置自检：给出可读错误，避免 App 侧只看到 traceback
    if not repo.is_dir():
        log.error("找不到 CosyVoice 仓库目录：%s（请先运行 scripts/install_cosyvoice.sh）", repo)
        return 2
    if not model_dir.is_dir():
        log.error("找不到模型目录：%s（请先运行 scripts/install_cosyvoice.sh）", model_dir)
        return 2
    missing = [name for name in ("llm.pt", "flow.pt", "hift.pt", "speech_tokenizer_v3.onnx",
                                 "campplus.onnx", "cosyvoice3.yaml")
               if not (model_dir / name).is_file()]
    if missing:
        log.error("模型目录缺少关键文件：%s（模型可能没下完，请重跑安装脚本）", ", ".join(missing))
        return 2
    if not voices_dir.is_dir():
        log.error("找不到音色目录：%s（请先运行 scripts/install_cosyvoice.sh --refs ...）", voices_dir)
        return 2

    port_error = check_port(args.host, args.port)
    if port_error:
        log.error("%s（若已有服务在跑可直接复用；否则换 --port）", port_error)
        return 2

    voices = []
    try:
        voices = load_voices(voices_dir)
    except Exception as exc:  # noqa: BLE001
        log.error("读取音色失败：%s", exc)
        return 2
    for voice in voices:
        if voice.channels > 1:
            log.warning("音色 %s 参考音是 %d 声道，已按单声道处理", voice.id, voice.channels)
        if voice.sample_rate and voice.sample_rate < 16000:
            log.warning("音色 %s 参考音采样率 %d < 16000，CosyVoice 会拒绝", voice.id, voice.sample_rate)

    engine = Engine(model_dir=model_dir, voices=voices, device=args.device,
                    threads=args.threads, warmup=not args.no_warmup,
                    voices_dir=voices_dir)
    app = build_app(engine)
    engine.start_loading()

    import uvicorn
    uvicorn.run(app, host=args.host, port=args.port, log_level=args.log_level,
                access_log=args.access_log, timeout_graceful_shutdown=5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
