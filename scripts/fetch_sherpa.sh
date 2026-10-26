#!/usr/bin/env bash
#
# 下载并校验 sherpa-onnx 静态库（TTS 引擎依赖，spec §3.1）。
#
# 产物（均不入库，app/Vendor/ 已 gitignore）：
#   app/Vendor/sherpa/lib/*.a                    # 13 个静态库
#   app/Vendor/sherpa/.cache/<archive>           # 下载缓存
#   app/Vendor/sherpa/.sherpa-version            # 版本/校验标记
#
# 用法：
#   bash scripts/fetch_sherpa.sh            # 缺库时下载；已就绪直接跳过
#   bash scripts/fetch_sherpa.sh --force    # 强制重新下载
#   bash scripts/fetch_sherpa.sh --check    # 只检查是否就绪（不联网，供 check.sh 用）
#
# 退出码：0 = 就绪；1 = 失败/缺失。
#
# 说明：官方 v2.0.0 osx-arm64-static-lib 包**只含 lib/**，不含头文件；
# C API 头 `c-api.h` 已随仓库放在 `app/Sources/CSherpaOnnx/include/`（Apache-2.0），
# 因此本脚本只负责 .a 库文件。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/app/Vendor/sherpa"
LIB_DIR="$VENDOR_DIR/lib"
CACHE_DIR="$VENDOR_DIR/.cache"
MARKER="$VENDOR_DIR/.sherpa-version"

VERSION="2.0.0"
ARCHIVE="sherpa-onnx-v${VERSION}-osx-arm64-static-lib.tar.bz2"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${ARCHIVE}"
SHA256="5e5bdce1d7fc834857278d8bb26f878de6a55c7085e589ed1e41a00baca643ec"

# 链接（app/Package.swift）需要的静态库；缺任何一个都视为未就绪。
REQUIRED_LIBS=(
  libsherpa-onnx-c-api.a
  libsherpa-onnx-core.a
  libsherpa-onnx-fst.a
  libsherpa-onnx-fstfar.a
  libsherpa-onnx-kaldifst-core.a
  libkaldi-decoder-core.a
  libssentencepiece_core.a
  libkaldi-native-fbank-core.a
  libkissfft-float.a
  libutf8proc.a
  libonnxruntime.a
)

say() { printf '[fetch-sherpa] %s\n' "$*" >&2; }
fail() { printf '[fetch-sherpa] ERROR: %s\n' "$*" >&2; exit 1; }

FORCE=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help)
      sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) fail "未知参数：${arg}（可用：--force / --check / --help）" ;;
  esac
done

missing=()
for lib in "${REQUIRED_LIBS[@]}"; do
  [ -f "$LIB_DIR/$lib" ] || missing+=("$lib")
done

if (( ${#missing[@]} == 0 )) && (( FORCE == 0 )); then
  say "静态库已就绪：${LIB_DIR}（${#REQUIRED_LIBS[@]} 个）"
  exit 0
fi
if (( CHECK_ONLY == 1 )); then
  say "静态库缺失：${missing[*]:-（目录不存在）}"
  say "运行 bash scripts/fetch_sherpa.sh 下载。"
  exit 1
fi

[ "$(uname -m)" = "arm64" ] || fail "此包仅支持 Apple Silicon（当前 $(uname -m)）"
command -v curl >/dev/null || fail "需要 curl"
command -v tar >/dev/null || fail "需要 tar"
command -v shasum >/dev/null || fail "需要 shasum"

mkdir -p "$LIB_DIR" "$CACHE_DIR"
archive_path="$CACHE_DIR/$ARCHIVE"

# 下载（支持断点续传；GitHub release 偶发限速，失败重试）。
if [ ! -f "$archive_path" ] || (( FORCE == 1 )); then
  (( FORCE == 1 )) && rm -f "$archive_path"
  say "下载 ${ARCHIVE}（约 20 MB）"
  curl -L --fail --retry 8 --retry-delay 3 --retry-connrefused \
    --connect-timeout 20 --continue-at - \
    -o "$archive_path" "$URL" \
    || fail "下载失败：$URL"
else
  say "使用已缓存的 $ARCHIVE"
fi

say "校验 SHA256"
actual="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
if [ "$actual" != "$SHA256" ]; then
  rm -f "$archive_path"
  fail "SHA256 不匹配（期望 ${SHA256}，实际 ${actual}）"
fi

say "解包到 $VENDOR_DIR"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sherpa.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
/usr/bin/tar -xjf "$archive_path" -C "$tmp_dir" || fail "tar 解包失败"

# 包的布局是 <name>/lib/*.a；把 lib 提升到 Vendor/sherpa/lib。
extracted_lib="$(find "$tmp_dir" -maxdepth 3 -type d -name lib -print -quit)"
[ -n "$extracted_lib" ] || fail "解包结果里没有 lib/ 目录"

rm -rf "$LIB_DIR"
mkdir -p "$LIB_DIR"
cp -f "$extracted_lib"/*.a "$LIB_DIR"/

missing=()
for lib in "${REQUIRED_LIBS[@]}"; do
  [ -f "$LIB_DIR/$lib" ] || missing+=("$lib")
done
(( ${#missing[@]} == 0 )) || fail "解包后仍缺库：${missing[*]}"

printf '%s %s\n' "$VERSION" "$SHA256" > "$MARKER"
say "完成：$LIB_DIR"
ls -1 "$LIB_DIR" | sed 's/^/  /' >&2
