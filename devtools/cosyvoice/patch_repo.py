#!/usr/bin/env python3
"""给 CosyVoice 上游仓库打最小化 macOS 补丁（幂等）。

为什么需要：
- 上游 `cosyvoice/cli/cosyvoice.py` 在模块顶层 `from modelscope import snapshot_download`。
  modelscope 在 macOS/Python3.10 上体积大、依赖多，而我们的模型目录是本地路径，
  根本不需要 snapshot_download。→ 改成 try/except，Missing 时给可读错误。
- 上游 `cosyvoice/dataset/processor.py` 在模块顶层 `import pyworld as pw`。pyworld 需要
  现场编译（PyPI 无 macOS arm64 wheel），而它只在训练期 `compute_f0` 用到。
  HyperPyYAML 解析 cosyvoice3.yaml 的 `!name:` 节点会 **导入整个模块**，所以不 patch 会直接失败。
  → 改成 try/except，缺失时置 None，仅在真正调用 compute_f0 时报错。
- `torch.load(..., weights_only=True)`、`torch.cuda.amp.autocast` 等在 CPU/macOS 下行为已足够；
  不做多余改动。

用法：
  python patch_repo.py --repo _local/cosyvoice/repo            # 打补丁
  python patch_repo.py --repo _local/cosyvoice/repo --check    # 只检查（0=已全部打好）
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

MODELSCOPE_MARKER = "COSYVOICE_MACOS_PATCH_MODELSCOPE"
PYWORLD_MARKER = "COSYVOICE_MACOS_PATCH_PYWORLD"
FLOW_STEPS_MARKER = "COSYVOICE_PATCH_FLOW_STEPS"

MODELSCOPE_OLD = "from modelscope import snapshot_download\n"
MODELSCOPE_NEW = """try:  # {marker}
    from modelscope import snapshot_download
except Exception:  # pragma: no cover - modelscope 在 macOS 上常装不上，本地模型目录不需要它
    def snapshot_download(model_id, **kwargs):
        raise RuntimeError(
            "modelscope 未安装，且未在本地找到模型目录：{{}}。".format(model_id)
            + "请用 --model-dir 指向已下载的 Fun-CosyVoice3-0.5B-2512 目录。"
        )
""".format(marker=MODELSCOPE_MARKER)

PYWORLD_OLD = "import pyworld as pw\n"
PYWORLD_NEW = """try:  # {marker}
    import pyworld as pw
except Exception:  # pragma: no cover - pyworld 需要现场编译（无 macOS arm64 wheel），仅训练期 compute_f0 用到
    pw = None
""".format(marker=PYWORLD_MARKER)


FLOW_STEPS_OLD = "n_timesteps=10,"
FLOW_STEPS_NEW = 'n_timesteps=int(os.environ.get("COSYVOICE_FLOW_STEPS", "10")),  # {marker}'


def _patch_file(path: Path, old: str, new: str, marker: str, count: int = 1) -> str:
    """返回 'patched' / 'already' / 'missing'（内部再细分 partial）。"""
    if not path.exists():
        return "missing"
    text = path.read_text(encoding="utf-8")
    if marker in text:
        return "already"
    occurrences = text.count(old)
    if occurrences == 0:
        return "missing"
    if occurrences < count:
        return f"partial({occurrences}/{count})"
    path.write_text(text.replace(old, new, count), encoding="utf-8")
    return "patched"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Patch CosyVoice repo for macOS (idempotent)")
    ap.add_argument("--repo", required=True, help="CosyVoice 仓库根目录")
    ap.add_argument("--check", action="store_true", help="只检查补丁状态，不写入")
    args = ap.parse_args(argv)

    repo = Path(args.repo).expanduser().resolve()
    targets = [
        ("modelscope 惰性导入", repo / "cosyvoice/cli/cosyvoice.py", MODELSCOPE_OLD, MODELSCOPE_NEW, MODELSCOPE_MARKER, 1),
        ("pyworld 惰性导入", repo / "cosyvoice/dataset/processor.py", PYWORLD_OLD, PYWORLD_NEW, PYWORLD_MARKER, 1),
        # flow 采样步数（默认 10）可由 COSYVOICE_FLOW_STEPS 覆盖，用于质量/速度折中
        ("flow 步数可配置", repo / "cosyvoice/flow/flow.py",
         FLOW_STEPS_OLD, FLOW_STEPS_NEW.format(marker=FLOW_STEPS_MARKER), FLOW_STEPS_MARKER, 3),
    ]

    rc = 0
    for label, path, old, new, marker, count in targets:
        if args.check:
            text = path.read_text(encoding="utf-8") if path.exists() else ""
            state = "ok" if marker in text else ("missing-file" if not path.exists() else "needed")
            print(f"[check] {label}: {state} ({path})")
            if state != "ok":
                rc = 1
            continue
        state = _patch_file(path, old, new, marker, count)
        print(f"[patch] {label}: {state} ({path})")
        if state in ("missing", "patched") or state.startswith("partial"):
            # patched 正常；missing/partial 说明上游文件变了或已用别的方式处理，需要人工确认
            if state != "patched":
                print(f"  WARN: 未找到预期代码片段，可能上游已修复或版本不同，请人工确认", file=sys.stderr)
                rc = 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
