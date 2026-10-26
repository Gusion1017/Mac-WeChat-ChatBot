#!/usr/bin/env python3
"""性能探针：区分冷/热、LLM/flow/hift 耗时、flow 步数、CPU/MPS(hybrid)、流式首块。

用法：
  python perf.py --mode cpu       --steps 10,8,6,4 --chars 20 --runs 2
  python perf.py --mode mps_hybrid --steps 6,4     --chars 20 --runs 2
  python perf.py --mode cpu --text "好啊，那就这么定了。" --steps 6 --runs 2

输出：每个 run 一行 JSON，最后汇总并落盘 `_local/cosyvoice/bench/perf_<mode>.json`。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import types
import wave
from pathlib import Path
from typing import List, Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
LOCAL = REPO_ROOT / "_local" / "cosyvoice"
REPO = LOCAL / "repo"
MODEL_DIR = LOCAL / "models" / "Fun-CosyVoice3-0.5B-2512"
VOICES = LOCAL / "voices"
BENCH = LOCAL / "bench"

SYS = "You are a helpful assistant."
EOP = "<|endofprompt|>"

TEXTS = {
    10: "好啊，那就这么定了。",
    20: "今天晚上一起去看电影吧，我已经买好票了。",
    50: "今天天气不错，我们出去走走吧。顺便去那家新开的咖啡馆坐一会儿，我听说他们家的手冲咖啡很好喝，还可以看到河边的风景。",
}


def add_paths() -> None:
    for p in (REPO, REPO / "third_party" / "Matcha-TTS"):
        if str(p) not in sys.path:
            sys.path.insert(0, str(p))


def save_wav(path: Path, speech, sample_rate: int) -> None:
    import numpy as np
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = (speech.squeeze(0).numpy() * 32767.0).round().astype(np.int16).tobytes()
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(pcm)


def install_hybrid_token2wav(model, llm_to_mps: bool = True) -> None:
    """flow 在 MPS，hift 留在 CPU；llm 按 llm_to_mps 决定（hift 有 float64 且 stft 在 MPS 不可用）。"""
    import torch
    from torch.nn import functional as F

    flow_dev = torch.device("mps")
    hift_dev = torch.device("cpu")
    cpu_dev = torch.device("cpu")
    model.model.llm.to(flow_dev if llm_to_mps else cpu_dev)
    model.model.flow.to(flow_dev)
    model.model.hift.to(hift_dev)
    model.model.device = flow_dev if llm_to_mps else cpu_dev
    model.frontend.device = flow_dev if llm_to_mps else cpu_dev

    def token2wav(self, token, prompt_token, prompt_feat, embedding, token_offset, uuid,
                  stream=False, finalize=False, speed=1.0):
        tts_mel, _ = self.flow.inference(
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
        tts_mel = tts_mel[:, :, token_offset * self.flow.token_mel_ratio:]
        if self.hift_cache_dict[uuid] is not None:
            cached = self.hift_cache_dict[uuid]["mel"]
            tts_mel = torch.concat([cached.to(tts_mel.device), tts_mel], dim=2)
            self.hift_cache_dict[uuid]["mel"] = tts_mel
        else:
            self.hift_cache_dict[uuid] = {"mel": tts_mel, "speech_offset": 0}
        if speed != 1.0:
            assert token_offset == 0 and finalize is True, "speed change only support non-stream inference mode"
            tts_mel = F.interpolate(tts_mel, size=int(tts_mel.shape[2] / speed), mode="linear")
        tts_speech, _ = self.hift.inference(speech_feat=tts_mel.to(hift_dev), finalize=finalize)
        tts_speech = tts_speech[:, self.hift_cache_dict[uuid]["speech_offset"]:]
        self.hift_cache_dict[uuid]["speech_offset"] += tts_speech.shape[1]
        return tts_speech

    model.model.token2wav = types.MethodType(token2wav, model.model)


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="cpu",
                    choices=["cpu", "mps_full", "mps_hybrid", "mps_flow"],
                    help="mps_hybrid=llm+flow 在 MPS；mps_flow=只有 flow 在 MPS（llm/hift 留 CPU）")
    ap.add_argument("--threads", type=int, default=0)
    ap.add_argument("--steps", default="10", help="flow 步数扫描，如 10,8,6,4")
    ap.add_argument("--runs", type=int, default=2, help="每个步数跑几次（第一次算冷）")
    ap.add_argument("--chars", type=int, default=20, choices=[10, 20, 50])
    ap.add_argument("--text", default=None)
    ap.add_argument("--stream", action="store_true")
    ap.add_argument("--voice", default="onee")
    args = ap.parse_args(argv)

    add_paths()
    import torch
    if args.threads > 0:
        torch.set_num_threads(args.threads)
    if args.mode.startswith("mps"):
        os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    torch.set_grad_enabled(False)
    from cosyvoice.cli.cosyvoice import AutoModel

    device_actual = "cpu"
    env = {
        "driver": "perf.py", "mode": args.mode, "torch": torch.__version__,
        "num_threads": torch.get_num_threads(), "cpu_count": os.cpu_count(),
        "mps_available": bool(torch.backends.mps.is_available()),
    }
    t0 = time.perf_counter()
    model = AutoModel(model_dir=str(MODEL_DIR))
    env["load_s"] = round(time.perf_counter() - t0, 2)
    env["sample_rate"] = model.sample_rate
    qwen = model.model.llm.llm.model
    env["attn_impl"] = getattr(qwen.config, "_attn_implementation", "?")
    env["qwen_dtype"] = str(next(qwen.parameters()).dtype)
    env["qwen_use_sliding"] = getattr(qwen.config, "use_sliding_window", None)

    voice_id = args.voice
    manifest = json.loads((VOICES / "voices.json").read_text(encoding="utf-8"))
    spec = next(v for v in manifest["voices"] if v["id"] == voice_id)
    prompt_wav = str(VOICES / spec["prompt_wav"])
    prompt_text = spec["prompt_text"]
    model.add_zero_shot_spk(f"{SYS}{EOP}{prompt_text}", prompt_wav, voice_id)

    if args.mode == "mps_hybrid":
        install_hybrid_token2wav(model, llm_to_mps=True)
        device_actual = "mps_hybrid"
    elif args.mode == "mps_flow":
        install_hybrid_token2wav(model, llm_to_mps=False)
        device_actual = "mps_flow"
    elif args.mode == "mps_full":
        dev = torch.device("mps")
        for m in (model.model.llm, model.model.flow, model.model.hift):
            m.to(dev)
        model.model.device = dev
        model.frontend.device = dev
        device_actual = "mps_full"
    env["device_actual"] = device_actual

    timers = {"flow_s": 0.0, "hift_s": 0.0}
    orig_token2wav = model.model.token2wav

    def timed_token2wav(*a, **k):
        t = time.perf_counter()
        out = orig_token2wav(*a, **k)
        timers["flow_s"] += time.perf_counter() - t
        return out
    model.model.token2wav = timed_token2wav
    orig_hift = model.model.hift.inference

    def timed_hift(*a, **k):
        t = time.perf_counter()
        out = orig_hift(*a, **k)
        timers["hift_s"] += time.perf_counter() - t
        return out
    model.model.hift.inference = timed_hift

    def sync():
        if device_actual.startswith("mps"):
            torch.mps.synchronize()

    text = args.text or TEXTS[args.chars]
    all_runs = []
    for step in [int(s) for s in args.steps.split(",") if s.strip()]:
        os.environ["COSYVOICE_FLOW_STEPS"] = str(step)
        step_runs = []
        for i in range(args.runs):
            timers["flow_s"] = timers["hift_s"] = 0.0
            sync()
            t_start = time.perf_counter()
            gen = model.inference_zero_shot(text, f"{SYS}{EOP}{prompt_text}", prompt_wav,
                                            zero_shot_spk_id=voice_id, stream=args.stream, speed=1.0)
            first_chunk = None
            chunks = []
            for item in gen:
                if first_chunk is None:
                    sync()
                    first_chunk = time.perf_counter() - t_start
                chunks.append(item["tts_speech"].detach().to("cpu", dtype=torch.float32))
            sync()
            total = time.perf_counter() - t_start
            speech = torch.cat(chunks, dim=1)
            audio_s = speech.shape[1] / model.sample_rate
            llm_s = max(0.0, total - timers["flow_s"])
            entry = {
                "step": step, "run": i, "chars": len(text),
                "audio_s": round(audio_s, 3), "total_s": round(total, 3),
                "first_chunk_s": round(first_chunk, 3) if first_chunk is not None else None,
                "rtf": round(total / audio_s, 3),
                "flow_s": round(timers["flow_s"], 3),
                "hift_s": round(timers["hift_s"], 3),
                "llm_s": round(llm_s, 3),
                "ms_per_audio_token": round(llm_s * 1000 / max(1, round(audio_s * 25)), 1),
            }
            step_runs.append(entry)
            all_runs.append(entry)
            tag = f"{device_actual}_s{step}_c{len(text)}_r{i}"
            save_wav(BENCH / f"perf_{tag}.wav", speech, model.sample_rate)
            print(json.dumps(entry, ensure_ascii=False), flush=True)
        warm = step_runs[1:] or step_runs
        print(json.dumps({"step": step, "warm_rtf_avg": round(sum(r["rtf"] for r in warm) / len(warm), 3),
                          "warm_flow_s_avg": round(sum(r["flow_s"] for r in warm) / len(warm), 3),
                          "warm_llm_s_avg": round(sum(r["llm_s"] for r in warm) / len(warm), 3)},
                         ensure_ascii=False), flush=True)

    env["text"] = text
    env["runs"] = all_runs
    overview = {}
    for step in sorted({r["step"] for r in all_runs}):
        rs = [r for r in all_runs if r["step"] == step]
        warm = rs[1:] or rs
        overview[str(step)] = {
            "warm_rtf": round(sum(r["rtf"] for r in warm) / len(warm), 3),
            "warm_total_s": round(sum(r["total_s"] for r in warm) / len(warm), 3),
            "warm_flow_s": round(sum(r["flow_s"] for r in warm) / len(warm), 3),
        }
    env["overview"] = overview
    print(json.dumps({"overview": overview, "meta": {k: v for k, v in env.items() if k not in ("runs", "overview")}},
                     ensure_ascii=False, indent=2))
    BENCH.mkdir(parents=True, exist_ok=True)
    out = BENCH / f"perf_{device_actual}_{len(text)}c.json"
    out.write_text(json.dumps(env, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"saved {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
