#!/usr/bin/env python3
"""devtools/cosyvoice/server.py 的音色元数据解析单测（标准库 unittest）。

只依赖 Python 标准库（不 import torch / fastapi / numpy）：用 `wave` + `struct`
生成 24 kHz 单声道 16-bit WAV，构造临时 voices 目录验证 v2「多条参考音频」元数据契约。

服务端**不做运行时音频拼接**：合成仍然只读 `prompt.wav` + `prompt_text`/`prompt.txt`。
这些用例只验证 `voices.json` 里 `references` 的解析、`reference_count` 统计、
无效片段跳过、缺失 `prompt.wav` 时跳过音色、目录扫描兜底与 `to_public()` 字段。

运行：

    python3 devtools/cosyvoice/test_server.py
"""

import importlib.util
import json
import logging
import struct
import tempfile
import unittest
import wave
from pathlib import Path

SERVER_PATH = Path(__file__).resolve().with_name("server.py")
SAMPLE_RATE = 24_000


def _load_server():
    """按文件路径加载 server.py（避免依赖工作目录 / 包结构）。"""
    spec = importlib.util.spec_from_file_location("cosyvoice_server_under_test", SERVER_PATH)
    if spec is None or spec.loader is None:  # pragma: no cover - 文件缺失才会走到
        raise RuntimeError(f"无法加载 {SERVER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server()
# 正常用例不关心预期的 warning（坏片段/坏条目本就会记日志），压到 ERROR 保持输出干净；
# 需要断言 warning 的用例用 assertLogs 临时把级别提高到 WARNING。
server.log.setLevel(logging.ERROR)


def write_wav(path: Path, seconds: float = 1.0, sample_rate: int = SAMPLE_RATE) -> None:
    """生成 24 kHz / 单声道 / 16-bit PCM 的静音 WAV（只用 wave + struct）。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = max(1, int(round(seconds * sample_rate)))
    payload = struct.pack("<h", 0) * frames
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(payload)


class VoiceFixtureTestCase(unittest.TestCase):
    """临时 voices 目录 + 构造工具。"""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="cosyvoice-server-test-")
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.voices = self.tmp / "voices"
        self.voices.mkdir()

    def make_voice_dir(self, voice_id: str, *, prompt_seconds: float = 1.0) -> Path:
        directory = self.voices / voice_id
        directory.mkdir(parents=True, exist_ok=True)
        write_wav(directory / "prompt.wav", seconds=prompt_seconds)
        return directory

    def make_refs(self, voice_dir: Path, count: int) -> None:
        for index in range(1, count + 1):
            write_wav(voice_dir / "refs" / f"ref-{index}.wav")
            (voice_dir / "refs" / f"ref-{index}.txt").write_text(
                f"第 {index} 条参考文本", encoding="utf-8"
            )

    def write_manifest(self, entries, *, version: int = 2) -> None:
        (self.voices / "voices.json").write_text(
            json.dumps({"version": version, "voices": entries}, ensure_ascii=False),
            encoding="utf-8",
        )

    def load(self, *, strict: bool = False):
        return server.load_voices(self.voices, strict_manifest=strict)


class LegacyManifestTest(VoiceFixtureTestCase):
    """用例 1：旧 manifest（无 references）→ 1 条。"""

    def test_legacy_entry_without_references_is_one(self) -> None:
        voice_dir = self.make_voice_dir("girl")
        (voice_dir / "prompt.txt").write_text("旧的参考文本", encoding="utf-8")
        self.write_manifest([{
            "id": "girl",
            "name": "预置女声",
            "mode": "zero_shot",
            "prompt_wav": "girl/prompt.wav",
            "prompt_text": "旧的参考文本",
            "personal_use_only": True,
            "builtin": True,
        }])

        voices = self.load()

        self.assertEqual([voice.id for voice in voices], ["girl"])
        voice = voices[0]
        self.assertEqual(voice.reference_count, 1)
        self.assertEqual(voice.prompt_text, "旧的参考文本")
        self.assertEqual(voice.to_public()["reference_count"], 1)


class MultiReferenceManifestTest(VoiceFixtureTestCase):
    """用例 2：2 条 references → reference_count == 2，prompt_text 原样保留。"""

    def test_two_references_are_counted_and_prompt_text_kept(self) -> None:
        voice_dir = self.make_voice_dir("custom-a", prompt_seconds=13.25)
        self.make_refs(voice_dir, 2)
        self.write_manifest([{
            "id": "custom-a",
            "name": "我的音色",
            "description": "两条参考音频",
            "mode": "zero_shot",
            "prompt_wav": "custom-a/prompt.wav",
            "prompt_text": "第一条\n第二条",
            "references": [
                {"audio": "custom-a/refs/ref-1.wav", "text": "第一条", "duration": 6.0},
                {"audio": "custom-a/refs/ref-2.wav", "text": "第二条", "duration": 7.0},
            ],
            "duration": 13.25,
            "personal_use_only": True,
            "builtin": False,
            "source": "app-import",
        }])

        voices = self.load()

        self.assertEqual(len(voices), 1)
        voice = voices[0]
        self.assertEqual(voice.reference_count, 2)
        self.assertEqual(voice.prompt_text, "第一条\n第二条")
        self.assertAlmostEqual(voice.duration_s, 13.25, places=2)
        self.assertEqual(voice.mode, "zero_shot")
        public = voice.to_public()
        self.assertEqual(public["reference_count"], 2)
        self.assertFalse(public["builtin"])
        self.assertEqual(public["source"], "app-import")

    def test_absolute_path_and_audio_path_key_are_supported(self) -> None:
        voice_dir = self.make_voice_dir("custom-abs")
        self.make_refs(voice_dir, 2)
        absolute = str((voice_dir / "refs" / "ref-1.wav").resolve())
        self.write_manifest([{
            "id": "custom-abs",
            "prompt_wav": "custom-abs/prompt.wav",
            "prompt_text": "a\nb",
            "references": [
                {"audio": absolute, "text": "a"},  # 绝对路径（在 voices 目录内）
                {"audio_path": "custom-abs/refs/ref-2.wav", "text": "b"},
            ],
        }])

        voices = self.load()

        self.assertEqual(len(voices), 1)
        self.assertEqual(voices[0].reference_count, 2)


class InvalidReferenceTest(VoiceFixtureTestCase):
    """用例 3：坏片段跳过；全部无效时回退 1。"""

    def test_bad_reference_entries_are_skipped_valid_ones_still_counted(self) -> None:
        voice_dir = self.make_voice_dir("custom-b")
        self.make_refs(voice_dir, 2)
        outside = self.tmp / "outside.wav"
        write_wav(outside)
        self.write_manifest([{
            "id": "custom-b",
            "prompt_wav": "custom-b/prompt.wav",
            "prompt_text": "a\nb",
            "references": [
                {"audio": "custom-b/refs/ref-1.wav"},          # 有效
                {"audio_path": "custom-b/refs/ref-2.wav"},     # 有效（audio_path 键）
                {"audio": "../outside.wav"},                    # 相对路径逃逸
                {"audio": str(outside.resolve())},              # 绝对路径但越出 voices 目录
                {"audio": "custom-b/refs/ref-404.wav"},         # 文件不存在
                {"audio": ""},                                  # 空路径
                "not-an-object",                                # 非对象
                42,                                             # 非对象
            ],
        }])

        voices = self.load()

        self.assertEqual(len(voices), 1)
        self.assertEqual(voices[0].reference_count, 2)

    def test_all_invalid_references_fall_back_to_one(self) -> None:
        self.make_voice_dir("custom-c")
        self.write_manifest([{
            "id": "custom-c",
            "prompt_wav": "custom-c/prompt.wav",
            "prompt_text": "只有一条参考文本",
            "references": [{"audio": "custom-c/refs/missing.wav"}],
        }])

        self.assertEqual(self.load()[0].reference_count, 1)

    def test_empty_or_non_list_references_fall_back_to_one(self) -> None:
        self.make_voice_dir("custom-empty")
        base = {"id": "custom-empty", "prompt_wav": "custom-empty/prompt.wav", "prompt_text": "x"}

        self.write_manifest([dict(base, references=[])])
        self.assertEqual(self.load()[0].reference_count, 1)

        self.write_manifest([dict(base, references="custom-empty/refs/ref-1.wav")])
        self.assertEqual(self.load()[0].reference_count, 1)


class MissingPromptWavTest(VoiceFixtureTestCase):
    """用例 4：references 存在但 prompt_wav 缺失 → 跳过该音色（不拿单片段 prompt 合成）。"""

    def test_voice_with_references_but_no_prompt_wav_is_skipped(self) -> None:
        broken = self.voices / "custom-broken"
        broken.mkdir()
        self.make_refs(broken, 2)  # 有 refs/，但没有 prompt.wav
        self.make_voice_dir("girl")
        self.write_manifest([
            {
                "id": "custom-broken",
                "name": "坏音色",
                "prompt_wav": "custom-broken/prompt.wav",
                "prompt_text": "a\nb",
                "references": [
                    {"audio": "custom-broken/refs/ref-1.wav"},
                    {"audio": "custom-broken/refs/ref-2.wav"},
                ],
            },
            {"id": "girl", "name": "预置女声", "prompt_wav": "girl/prompt.wav"},
        ])

        with self.assertLogs(server.log, level="WARNING") as captured:
            voices = self.load()

        self.assertEqual([voice.id for voice in voices], ["girl"])
        self.assertTrue(any("跳过该音色" in line for line in captured.output))

    def test_missing_prompt_wav_key_is_skipped_even_in_strict_mode(self) -> None:
        broken = self.voices / "custom-keyless"
        broken.mkdir()
        self.make_refs(broken, 1)
        self.write_manifest([{
            "id": "custom-keyless",
            "references": [{"audio": "custom-keyless/refs/ref-1.wav"}],
        }])

        with self.assertLogs(server.log, level="WARNING"):
            voices = self.load(strict=True)

        self.assertEqual(voices, [])


class DirectoryScanTest(VoiceFixtureTestCase):
    """用例 5：manifest 缺失时目录扫描统计 refs/ref-*.wav；仍要求 prompt.wav 存在。"""

    def test_directory_scan_counts_refs_and_requires_prompt_wav(self) -> None:
        multi = self.make_voice_dir("custom-multi")
        self.make_refs(multi, 3)
        (multi / "refs" / "notes.txt").write_text("不是音频", encoding="utf-8")
        write_wav(multi / "refs" / "other.wav")  # 非 ref-* 命名不计

        legacy = self.make_voice_dir("custom-legacy")
        (legacy / "prompt.txt").write_text("旧参考文本", encoding="utf-8")

        half = self.voices / "custom-half"
        half.mkdir()
        self.make_refs(half, 2)  # 有 refs 但没有 prompt.wav → 不收录

        voices = self.load()

        by_id = {voice.id: voice for voice in voices}
        self.assertEqual(sorted(by_id), ["custom-legacy", "custom-multi"])
        self.assertEqual(by_id["custom-multi"].reference_count, 3)
        self.assertEqual(by_id["custom-legacy"].reference_count, 1)
        self.assertEqual(by_id["custom-legacy"].prompt_text, "旧参考文本")

    def test_voice_without_refs_dir_is_one(self) -> None:
        self.make_voice_dir("custom-single")
        self.assertEqual(self.load()[0].reference_count, 1)


class PublicPayloadTest(VoiceFixtureTestCase):
    """用例 6：to_public()（/voices、/health.voices_detail、/voices/reload 共用）含 reference_count。"""

    def test_to_public_always_exposes_reference_count(self) -> None:
        voice_dir = self.make_voice_dir("custom-x")
        explicit = server.Voice(
            id="custom-x",
            name="X",
            description="",
            prompt_wav=voice_dir / "prompt.wav",
            reference_count=3,
        )
        public = explicit.to_public()
        self.assertEqual(public["reference_count"], 3)
        self.assertIsInstance(public["reference_count"], int)

        default = server.Voice(
            id="legacy", name="L", description="", prompt_wav=voice_dir / "prompt.wav"
        )
        self.assertEqual(default.to_public()["reference_count"], 1)

    def test_loaded_voice_public_payload_contains_reference_count(self) -> None:
        voice_dir = self.make_voice_dir("custom-p")
        self.make_refs(voice_dir, 2)
        self.write_manifest([{
            "id": "custom-p",
            "prompt_wav": "custom-p/prompt.wav",
            "prompt_text": "a\nb",
            "references": [
                {"audio": "custom-p/refs/ref-1.wav"},
                {"audio": "custom-p/refs/ref-2.wav"},
            ],
        }])

        payload = self.load()[0].to_public()
        self.assertEqual(payload["reference_count"], 2)


class ContractVersionTest(unittest.TestCase):
    def test_version_bumped_for_reference_count(self) -> None:
        self.assertEqual(server.VERSION, "1.1.0")


if __name__ == "__main__":
    unittest.main(verbosity=2)
