#!/usr/bin/env python3
"""CosyVoice3 冒烟测试 / 基准测试。

用法：
    # 冒烟：repo 自带 prompt + 官方 zero_shot 示例，输出 24k wav
    python bench.py smoke --device cpu

    # 三音色样音 + RTF
    python bench.py voices --device cpu --out _local/cosyvoice/samples

    # 本机音色 zero_shot vs cross_lingual 客观对比（campplus 说话人相似度）
    python bench.py compare-girl --device cpu

所有结果 JSON 落盘到 `_local/cosyvoice/bench/`。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import wave
from pathlib import Path
from typing import Dict, List, Optional, Tuple

REPO_ROOT = Path(__file__).resolve().parents[2]
LOCAL = REPO_ROOT / "_local" / "cosyvoice"
REPO = LOCAL / "repo"
MODEL_DIR = LOCAL / "models" / "Fun-CosyVoice3-0.5B-2512"
VOICES_DIR = LOCAL / "voices"
BENCH_DIR = LOCAL / "bench"
SAMPLES_DIR = LOCAL / "samples"

SYS = "You are a helpful assistant."
EOP = "<|endofprompt|>"

SMOKE_TEXT = "收到好友从远方寄来的生日礼物，那份意外的惊喜与深深的祝福让我心中充满了甜蜜的快乐，笑容如花儿般绽放。"
SMOKE_PROMPT_TEXT = "希望你以后能够做的比我还好呦。"
VOICE_SAMPLE_TEXT = "今天天气不错，我们出去走走吧。"


def add_paths() -> None:
    for p in (REPO, REPO / "third_party" / "Matcha-TTS"):
        if str(p) not in sys.path:
            sys.path.insert(0, str(p))


def wav_info(path: Path) -> Dict[str, float]:
    with wave.open(str(path), "rb") as w:
        frames, rate = w.getnframes(), w.getframerate()
        return {"duration": round(frames / rate, 3), "sample_rate": rate,
                "channels": w.getnchannels(), "bytes": path.stat().st_size}


def save_wav(path: Path, speech, sample_rate: int) -> Dict[str, float]:
    import numpy as np
    path.parent.mkdir(parents=True, exist_ok=True)
    data = speech.detach().to("cpu", dtype=None, copy=True).squeeze(0)
    pcm = (data.numpy() * 32767.0).round().astype(np.int16).tobytes()
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(pcm)
    return wav_info(path)


def concat(chunks: List) -> object:
    import torch
    return torch.cat([c.detach().to("cpu", dtype=torch.float32) for c in chunks], dim=1)


def rss_mb() -> float:
    import resource
    v = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return round(v / (1024 * 1024), 1) if sys.platform == "darwin" else round(v / 1024, 1)


def set_threads(n: int) -> None:
    import torch
    if n > 0:
        torch.set_num_threads(n)


def load_model(device: str):
    """返回 (model, load_s, device_actual)。"""
    import torch
    from cosyvoice.cli.cosyvoice import AutoModel
    t0 = time.perf_counter()
    model = AutoModel(model_dir=str(MODEL_DIR))
    load_s = time.perf_counter() - t0
    actual = "cpu"
    if device in ("mps", "auto") and torch.backends.mps.is_available():
        try:
            dev = torch.device("mps")
            for m in (model.model.llm, model.model.flow, model.model.hift):
                m.to(dev)
            model.model.device = dev
            model.frontend.device = dev
            actual = "mps"
        except Exception as exc:  # noqa: BLE001
            print(f"WARN: 切 MPS 失败，回退 CPU：{exc}")
    return model, load_s, actual


def synth(model, text: str, prompt_text: str, prompt_wav: str,
          mode: str = "zero_shot", speed: float = 1.0,
          zero_shot_spk_id: str = "") -> Tuple[object, float, float]:
    """返回 (speech tensor, 首包秒, 总耗时秒)。"""
    import torch
    kwargs = {"stream": False, "speed": speed}
    if zero_shot_spk_id:
        kwargs["zero_shot_spk_id"] = zero_shot_spk_id
    with torch.inference_mode():
        t0 = time.perf_counter()
        if mode == "cross_lingual":
            gen = model.inference_cross_lingual(f"{SYS}{EOP}{text}", prompt_wav, **kwargs)
        elif mode == "instruct":
            gen = model.inference_instruct2(text, f"{SYS} {prompt_text}{EOP}", prompt_wav, **kwargs)
        else:
            gen = model.inference_zero_shot(text, f"{SYS}{EOP}{prompt_text}", prompt_wav, **kwargs)
        chunks, first = [], None
        for item in gen:
            if first is None:
                first = time.perf_counter() - t0
            chunks.append(item["tts_speech"])
        total = time.perf_counter() - t0
    return concat(chunks), first, total


def cmd_smoke(args) -> int:
    add_paths()
    set_threads(args.threads)
    model, load_s, device = load_model(args.device)
    sr = model.sample_rate
    prompt_wav = str(REPO / "asset" / "zero_shot_prompt.wav")
    # 官方 CosyVoice3 用法：prompt_text 带系统前缀
    speech, first, total = synth(model, SMOKE_TEXT, SMOKE_PROMPT_TEXT, prompt_wav)
    out = BENCH_DIR / f"smoke_{device}.wav"
    info = save_wav(out, speech, sr)
    result = {
        "kind": "smoke", "device": device, "sample_rate": sr, "load_s": round(load_s, 2),
        "first_packet_s": round(first, 3), "synth_s": round(total, 3),
        "audio_s": info["duration"], "rtf": round(total / info["duration"], 3),
        "rss_mb": rss_mb(), "wav": str(out), "prompt": "asset/zero_shot_prompt.wav",
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    BENCH_DIR.mkdir(parents=True, exist_ok=True)
    (BENCH_DIR / f"smoke_{device}.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


def load_voice_specs() -> List[dict]:
    manifest = VOICES_DIR / "voices.json"
    if manifest.is_file():
        return json.loads(manifest.read_text(encoding="utf-8"))["voices"]
    return []


def cmd_voices(args) -> int:
    add_paths()
    set_threads(args.threads)
    model, load_s, device = load_model(args.device)
    sr = model.sample_rate
    specs = load_voice_specs()
    if not specs:
        print("ERROR: 没有 voices.json，请先在 App 音色管理中导入音色", file=sys.stderr)
        return 2
    out_dir = Path(args.out)
    results = {"kind": "voices", "device": device, "sample_rate": sr,
               "load_s": round(load_s, 2), "voices": []}
    for spec in specs:
        vid = spec["id"]
        wav = VOICES_DIR / spec["prompt_wav"]
        # ① 冷启动：先缓存 prompt 特征（等价 server 启动时的行为）
        t0 = time.perf_counter()
        model.add_zero_shot_spk(f"{SYS}{EOP}{spec['prompt_text']}" if spec["prompt_text"] else "",
                                str(wav), vid)
        prime_s = time.perf_counter() - t0
        # ② 第一次合成（含 di/flow 首次分配）
        speech, first, total = synth(model, VOICE_SAMPLE_TEXT, spec["prompt_text"], str(wav),
                                     mode=spec.get("mode", "zero_shot"), zero_shot_spk_id=vid)
        info = save_wav(out_dir / f"{vid}_sample.wav", speech, sr)
        # ③ 第二次合成（稳定态 RTF）
        speech2, first2, total2 = synth(model, VOICE_SAMPLE_TEXT, spec["prompt_text"], str(wav),
                                        mode=spec.get("mode", "zero_shot"), zero_shot_spk_id=vid)
        info2 = save_wav(out_dir / f"{vid}_sample2.wav", speech2, sr)
        entry = {
            "id": vid, "name": spec.get("name"), "mode": spec.get("mode", "zero_shot"),
            "prompt_prime_s": round(prime_s, 3),
            "first": {"first_packet_s": round(first, 3), "synth_s": round(total, 3),
                      "audio_s": info["duration"], "rtf": round(total / info["duration"], 3)},
            "second": {"first_packet_s": round(first2, 3), "synth_s": round(total2, 3),
                       "audio_s": info2["duration"], "rtf": round(total2 / info2["duration"], 3)},
            "rss_mb": rss_mb(),
            "wav": str(out_dir / f"{vid}_sample.wav"),
        }
        results["voices"].append(entry)
        print(json.dumps(entry, ensure_ascii=False))
    print(json.dumps({k: v for k, v in results.items() if k != "voices"}, ensure_ascii=False))
    BENCH_DIR.mkdir(parents=True, exist_ok=True)
    (BENCH_DIR / f"voices_{device}.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


def _spk_embedding(model, wav_path: Path):
    """用 campplus 提取说话人 embedding（与合成同一条路径）。"""
    import numpy as np
    import torch
    frontend = model.frontend
    emb = frontend._extract_spk_embedding(str(wav_path))
    return emb.flatten().to("cpu", dtype=torch.float32)


def cmd_compare_girl(args) -> int:
    add_paths()
    set_threads(args.threads)
    model, load_s, device = load_model(args.device)
    sr = model.sample_rate
    spec = next(s for s in load_voice_specs() if s["id"] == "girl")
    prompt_wav = VOICES_DIR / spec["prompt_wav"]
    ref_emb = _spk_embedding(model, prompt_wav)

    results = {"kind": "compare_girl", "device": device, "load_s": round(load_s, 2),
               "text": VOICE_SAMPLE_TEXT, "variants": []}
    for mode in ("zero_shot", "cross_lingual"):
        speech, first, total = synth(model, VOICE_SAMPLE_TEXT, spec["prompt_text"],
                                     str(prompt_wav), mode=mode)
        out = SAMPLES_DIR / f"girl_{mode}.wav"
        info = save_wav(out, speech, sr)
        # 生成音频的说话人相似度
        emb = _spk_embedding(model, out)
        cos = float(torch.nn.functional.cosine_similarity(ref_emb, emb, dim=0))
        entry = {"mode": mode, "wav": str(out), "audio_s": info["duration"],
                 "first_packet_s": round(first, 3), "synth_s": round(total, 3),
                 "rtf": round(total / info["duration"], 3),
                 "campplus_cosine_to_prompt": round(cos, 4)}
        results["variants"].append(entry)
        print(json.dumps(entry, ensure_ascii=False))
    BENCH_DIR.mkdir(parents=True, exist_ok=True)
    (BENCH_DIR / "compare_girl.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="CosyVoice3 smoke / benchmark")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("smoke", cmd_smoke), ("voices", cmd_voices),
                     ("compare-girl", cmd_compare_girl)):
        p = sub.add_parser(name)
        p.add_argument("--device", default=os.environ.get("COSYVOICE_DEVICE", "cpu"),
                       choices=["cpu", "mps", "auto"])
        p.add_argument("--threads", type=int, default=int(os.environ.get("COSYVOICE_THREADS", "0")))
        p.add_argument("--out", default=str(SAMPLES_DIR))
        p.set_defaults(func=fn)
    args = ap.parse_args(argv)
    import torch
    torch.set_grad_enabled(False)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
