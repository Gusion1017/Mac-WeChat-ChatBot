#!/usr/bin/env bash
#
# 从 bridge/ 源码构建 bridge/onebot（macOS arm64，CGO 静态链接 Frida）。
#
# 固定版本：
#   Go 1.25.14 (darwin-arm64)
#   frida-core-devkit 17.8.0 (macos-arm64)
#
# 所有下载/缓存默认放在 /tmp/chatbot-bridge-cache，不修改系统 PATH，
# 不安装 Homebrew 包，也不写用户的 Go 全局配置（GOENV=off）。
#
# 用法：
#   scripts/build_bridge.sh                 # 增量构建（复用缓存）
#   BRIDGE_CLEAN=1 scripts/build_bridge.sh  # 删除旧二进制和 Go build cache 后重建
#   BRIDGE_SKIP_TESTS=1 scripts/build_bridge.sh
#   BRIDGE_CACHE_DIR=/path/to/cache scripts/build_bridge.sh
#
set -euo pipefail

GO_VERSION="1.25.14"
GO_SHA256="5b26c0b6f308240fca2614fb02f622cfcc8c0cc3b69c78bba4845489a4590259"
GO_ARCHIVE_NAME="go${GO_VERSION}.darwin-arm64.tar.gz"

FRIDA_VERSION="17.8.0"
FRIDA_DEVKIT_NAME="frida-core-devkit-${FRIDA_VERSION}-macos-arm64"
FRIDA_DEVKIT_SHA256="7606cd0eda21829e268ed66e1ac7dcd819570baee7b7049a96e8986969bf32d1"
FRIDA_DEVKIT_URL="https://github.com/frida/frida/releases/download/${FRIDA_VERSION}/${FRIDA_DEVKIT_NAME}.tar.xz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BRIDGE_DIR="${ROOT_DIR}/bridge"
BIN="${BRIDGE_DIR}/onebot"
CACHE_DIR="${BRIDGE_CACHE_DIR:-/tmp/chatbot-bridge-cache}"
GO_ROOT="${CACHE_DIR}/go${GO_VERSION}"
GO_ARCHIVE="${CACHE_DIR}/${GO_ARCHIVE_NAME}"
DEVKIT_DIR="${CACHE_DIR}/${FRIDA_DEVKIT_NAME}"
DEVKIT_ARCHIVE="${CACHE_DIR}/${FRIDA_DEVKIT_NAME}.tar.xz"

info() { printf '==> %s\n' "$*"; }
warn() { printf '⚠️  %b\n' "$*" >&2; }
fail() { printf '❌ %b\n' "$*" >&2; exit 1; }

safe_rm_rf() {
  local target="$1"
  case "${target}" in
    "${CACHE_DIR}"/*) ;;
    *) fail "拒绝删除缓存目录之外的路径：${target}" ;;
  esac
  [[ "${target}" != "${CACHE_DIR}" ]] || fail "拒绝删除缓存根目录"
  rm -rf -- "${target}"
}

verify_sha256() {
  local file="$1" want="$2" got
  [[ -f "${file}" ]] || fail "缺少文件：${file}"
  got="$(shasum -a 256 "${file}" | awk '{print $1}')"
  [[ "${got}" == "${want}" ]] \
    || fail "SHA256 校验失败：${file}\n  期望：${want}\n  实际：${got}\n  请删除该文件后重试。"
  info "SHA256 校验通过：$(basename "${file}")"
}

download_go_archive() {
  local url
  for url in \
    "https://go.dev/dl/${GO_ARCHIVE_NAME}" \
    "https://golang.google.cn/dl/${GO_ARCHIVE_NAME}" \
    "https://mirrors.aliyun.com/golang/${GO_ARCHIVE_NAME}"
  do
    info "下载 Go ${GO_VERSION}：${url}"
    if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 \
        -o "${GO_ARCHIVE}.part" "${url}"; then
      mv "${GO_ARCHIVE}.part" "${GO_ARCHIVE}"
      return 0
    fi
    rm -f "${GO_ARCHIVE}.part"
    warn "该下载源失败，尝试下一个…"
  done
  return 1
}

download_devkit_archive() {
  info "下载 frida-core-devkit ${FRIDA_VERSION}：${FRIDA_DEVKIT_URL}"
  if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 \
      -o "${DEVKIT_ARCHIVE}.part" "${FRIDA_DEVKIT_URL}"; then
    rm -f "${DEVKIT_ARCHIVE}.part"
    fail "frida-core-devkit 下载失败。可手动下载后放到：${DEVKIT_ARCHIVE}\n  ${FRIDA_DEVKIT_URL}"
  fi
  mv "${DEVKIT_ARCHIVE}.part" "${DEVKIT_ARCHIVE}"
}

# ---------- 环境检查 ----------

[[ "$(uname -s)" == "Darwin" ]] || fail "本脚本只支持 macOS。"
[[ "$(uname -m)" == "arm64" ]] || fail "当前架构 $(uname -m)；本脚本/预编译 Frida devkit 只支持 arm64（Apple Silicon）。"

command -v curl >/dev/null 2>&1 || fail "缺少 curl。"
command -v shasum >/dev/null 2>&1 || fail "缺少 shasum。"
xcrun --find clang >/dev/null 2>&1 \
  || fail "未找到 Xcode 命令行工具。请先执行：xcode-select --install（或安装完整 Xcode）。"
SDKROOT="$(xcrun --show-sdk-path 2>/dev/null)" || fail "无法获取 macOS SDK 路径（xcrun --show-sdk-path）。"
[[ -d "${SDKROOT}" ]] || fail "macOS SDK 不存在：${SDKROOT}"

[[ -f "${BRIDGE_DIR}/go.mod" ]] || fail "缺少 ${BRIDGE_DIR}/go.mod；请确认在项目仓库内运行。"
[[ -f "${BRIDGE_DIR}/script.js" ]] || fail "缺少 ${BRIDGE_DIR}/script.js；onebot 运行时从当前目录读取它。"
for required in main.go http.go websocket.go worker.go proto; do
  [[ -e "${BRIDGE_DIR}/${required}" ]] || fail "bridge/ 缺少 ${required}；请检查源码是否完整。"
done

mkdir -p "${CACHE_DIR}"
CACHE_DIR="$(cd "${CACHE_DIR}" && pwd)"
GO_ROOT="${CACHE_DIR}/go${GO_VERSION}"
GO_ARCHIVE="${CACHE_DIR}/${GO_ARCHIVE_NAME}"
DEVKIT_DIR="${CACHE_DIR}/${FRIDA_DEVKIT_NAME}"
DEVKIT_ARCHIVE="${CACHE_DIR}/${FRIDA_DEVKIT_NAME}.tar.xz"

if [[ "${BRIDGE_CLEAN:-0}" == "1" ]]; then
  info "BRIDGE_CLEAN=1：清理旧二进制与 Go build cache…"
  rm -f -- "${BIN}"
  safe_rm_rf "${CACHE_DIR}/go-build"
fi

# ---------- Go 工具链 ----------

if [[ ! -x "${GO_ROOT}/bin/go" ]]; then
  if [[ -f "${GO_ARCHIVE}" ]]; then
    if ! ( shasum -a 256 "${GO_ARCHIVE}" | awk '{print $1}' | grep -qx "${GO_SHA256}" ); then
      warn "缓存的 Go 压缩包校验失败，重新下载…"
      rm -f "${GO_ARCHIVE}"
    fi
  fi
  if [[ ! -f "${GO_ARCHIVE}" ]]; then
    download_go_archive || fail "Go ${GO_VERSION} 下载失败（已尝试 go.dev / golang.google.cn / 阿里云镜像）。"
  fi
  verify_sha256 "${GO_ARCHIVE}" "${GO_SHA256}"
  safe_rm_rf "${CACHE_DIR}/go"
  safe_rm_rf "${GO_ROOT}"
  info "解压 Go ${GO_VERSION} 到 ${GO_ROOT}…"
  tar -C "${CACHE_DIR}" -xzf "${GO_ARCHIVE}"
  mv "${CACHE_DIR}/go" "${GO_ROOT}"
fi

GO_BIN="${GO_ROOT}/bin/go"
"${GO_BIN}" version | grep -q "go${GO_VERSION} " \
  || fail "Go 版本不匹配：$("${GO_BIN}" version)。期望 go${GO_VERSION}。"

# ---------- Frida devkit ----------

if [[ ! -f "${DEVKIT_DIR}/libfrida-core.a" || ! -f "${DEVKIT_DIR}/frida-core.h" ]]; then
  if [[ -f "${DEVKIT_ARCHIVE}" ]]; then
    if ! ( shasum -a 256 "${DEVKIT_ARCHIVE}" | awk '{print $1}' | grep -qx "${FRIDA_DEVKIT_SHA256}" ); then
      warn "缓存的 devkit 压缩包校验失败，重新下载…"
      rm -f "${DEVKIT_ARCHIVE}"
    fi
  fi
  [[ -f "${DEVKIT_ARCHIVE}" ]] || download_devkit_archive
  verify_sha256 "${DEVKIT_ARCHIVE}" "${FRIDA_DEVKIT_SHA256}"
  safe_rm_rf "${DEVKIT_DIR}"
  extract_dir="$(mktemp -d "${CACHE_DIR}/devkit-extract.XXXXXX")"
  info "解压 frida-core-devkit…"
  tar -xf "${DEVKIT_ARCHIVE}" -C "${extract_dir}"
  [[ -f "${extract_dir}/libfrida-core.a" ]] || fail "devkit 解压后缺少 libfrida-core.a"
  mv "${extract_dir}" "${DEVKIT_DIR}"
fi

# ---------- 构建环境（不污染用户全局环境） ----------

export PATH="${GO_ROOT}/bin:${PATH}"
export GOTOOLCHAIN=local
export GOENV=off
export GOARCH=arm64
export CGO_ENABLED=1
export GOCACHE="${CACHE_DIR}/go-build"
export GOMODCACHE="${CACHE_DIR}/go-mod"
export GOPATH="${CACHE_DIR}/gopath"
export CC="$(xcrun --find clang)"
export CXX="$(xcrun --find clang++)"
export SDKROOT
# frida-go 已带 -lfrida-core，这里只需提供 -L；额外 -lfrida-core 会产生重复库警告。
export CGO_CFLAGS="-I${DEVKIT_DIR} ${CGO_CFLAGS:-}"
export CGO_LDFLAGS="-L${DEVKIT_DIR} ${CGO_LDFLAGS:-}"

info "环境：$(uname -m) / macOS $(sw_vers -productVersion) / $( "${GO_BIN}" version | awk '{print $3}' ) / Frida ${FRIDA_VERSION}"

# ---------- Go modules ----------

info "下载 Go modules（缓存：${GOMODCACHE}）…"
if ! ( cd "${BRIDGE_DIR}" && "${GO_BIN}" mod download ); then
  warn "默认 GOPROXY 失败，改用 https://goproxy.cn,direct 重试…"
  ( cd "${BRIDGE_DIR}" && GOPROXY="https://goproxy.cn,direct" "${GO_BIN}" mod download ) \
    || fail "Go modules 下载失败。请检查网络，或手动设置 GOPROXY=https://goproxy.cn,direct 后重试。"
fi

# ---------- 编译 ----------

info "编译 bridge/onebot（arm64，CGO，Frida 静态链接；-trimpath -ldflags=\"-s -w\"）…"
( cd "${BRIDGE_DIR}" && "${GO_BIN}" build -trimpath -buildvcs=false -ldflags="-s -w" -o "${BIN}" . )

[[ -x "${BIN}" ]] || fail "编译未产出可执行文件：${BIN}"
file "${BIN}" | grep -q 'Mach-O 64-bit executable arm64' \
  || fail "产物不是 Mach-O arm64：$(file "${BIN}")"
"${BIN}" -h >/dev/null 2>&1 \
  || fail "onebot -h 运行失败（动态库/签名/架构问题）。"
info "二进制自检通过：Mach-O arm64，-h 正常。"

# bridge 运行时只读取自己目录下的 script.js；若仓库里有 hook/script.js，检查两者一致。
HOOK_SCRIPT="${ROOT_DIR}/hook/script.js"
if [[ -f "${HOOK_SCRIPT}" && -f "${BRIDGE_DIR}/script.js" ]]; then
  hook_sha="$(shasum -a 256 "${HOOK_SCRIPT}" | awk '{print $1}')"
  bridge_sha="$(shasum -a 256 "${BRIDGE_DIR}/script.js" | awk '{print $1}')"
  if [[ "${hook_sha}" != "${bridge_sha}" ]]; then
    warn "bridge/script.js 与 hook/script.js 不一致；bridge 运行时读取前者，发布前请同步。"
  else
    info "script.js 与 hook/script.js 一致（${hook_sha}）。"
  fi
fi

# ---------- 本地接口自检（不依赖 Gadget） ----------

if [[ "${BRIDGE_SKIP_TESTS:-0}" != "1" ]]; then
  info "运行 HTTP 鉴权 / WS 动作契约测试（httptest，不连接 Frida）…"
  ( cd "${BRIDGE_DIR}" && "${GO_BIN}" test -count=1 -timeout=120s \
      -run 'TestSendHandlerAuth|TestWebSocketGetLoginInfo' . ) \
    || fail "本地契约测试失败。"
fi

# ---------- 输出 ----------

info "构建完成"
printf '  binary : %s\n' "${BIN}"
printf '  size   : %s\n' "$(du -h "${BIN}" | awk '{print $1}')"
printf '  arch   : %s\n' "$(file -b "${BIN}")"
printf '  Go     : %s\n' "$("${GO_BIN}" version)"
printf '  Frida  : %s（%s）\n' "${FRIDA_VERSION}" "${DEVKIT_DIR}"
printf '  script : %s\n' "${BRIDGE_DIR}/script.js"
printf '  运行   : %s/scripts/run_bridge.sh\n' "${ROOT_DIR}"
