#!/usr/bin/env python3
"""检查仓库内 Markdown 的相对链接是否指向真实存在的文件。

用法：
    python3 scripts/check_docs.py            # 检查全部文档
    python3 scripts/check_docs.py docs/      # 只检查指定目录

规则：
- 只检查相对路径链接（http/https/mailto/锚点/绝对路径跳过）；
- 忽略围栏代码块中的示例；
- 支持 `[文字](路径)`、`![图片](路径)` 与 `<带空格的路径>`；
- 发现失效链接时列出 `文件:行号 → 目标`，退出码 1。
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SKIP_DIR_NAMES = {
    ".git",
    ".build",
    ".build-release",
    ".build-feature",
    ".build-memory",
    "node_modules",
    "dist",
    "_local",
    "_research",
    "__pycache__",
    ".swiftpm",
}

LINK_RE = re.compile(r"!?\[[^\]]*\]\(\s*(<[^>]+>|[^)\s]+)(?:\s+[\"'][^\"']*[\"'])?\s*\)")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE_RE = re.compile(r"`[^`]*`")


def iter_markdown_files(targets: list[str]):
    for target in targets:
        path = os.path.abspath(target)
        if os.path.isfile(path) and path.endswith(".md"):
            yield path
            continue
        for dirpath, dirnames, filenames in os.walk(path):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_NAMES]
            for name in sorted(filenames):
                if name.endswith(".md"):
                    yield os.path.join(dirpath, name)


def iter_links(path: str):
    """返回 (行号, 原始目标)。跳过围栏代码块。"""
    in_fence = False
    with open(path, encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            if FENCE_RE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            # 行内代码里的 `](...)` 是示例，不是链接
            line = INLINE_CODE_RE.sub("", line)
            for match in LINK_RE.finditer(line):
                raw = match.group(1).strip()
                if raw.startswith("<") and raw.endswith(">"):
                    raw = raw[1:-1].strip()
                yield lineno, raw


def should_skip(target: str) -> bool:
    lowered = target.lower()
    if not target:
        return True
    if lowered.startswith(("http://", "https://", "mailto:", "tel:", "file://", "data:")):
        return True
    if target.startswith("#"):
        return True
    if target.startswith("/") or target.startswith("~"):
        return True
    return False


def check_file(path: str) -> list[tuple[int, str]]:
    failures: list[tuple[int, str]] = []
    for lineno, raw in iter_links(path):
        if should_skip(raw):
            continue
        target = raw.split("#", 1)[0].split("?", 1)[0].strip()
        if not target:
            continue
        resolved = os.path.normpath(os.path.join(os.path.dirname(path), target))
        if not os.path.exists(resolved):
            failures.append((lineno, raw))
    return failures


def main(argv: list[str]) -> int:
    targets = argv[1:] or [ROOT]
    files = list(iter_markdown_files(targets))
    if not files:
        print("没有找到 Markdown 文件", file=sys.stderr)
        return 1

    broken = 0
    for path in files:
        for lineno, raw in check_file(path):
            broken += 1
            rel = os.path.relpath(path, ROOT)
            print(f"{rel}:{lineno} → {raw}")

    if broken:
        print(f"\n❌ 发现 {broken} 个失效的相对链接（共检查 {len(files)} 个文件）")
        return 1

    print(f"✅ 文档链接检查通过（{len(files)} 个文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
