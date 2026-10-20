#!/usr/bin/env bash
# Download a pinned Frida Gadget build and verify it is a universal Mach-O.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${FRIDA_GADGET_VERSION:-17.8.0}"
DEST="$ROOT_DIR/hook/gadget/FridaGadget.dylib"
URL="https://github.com/frida/frida/releases/download/${VERSION}/frida-gadget-${VERSION}-macos-universal.dylib.xz"
mkdir -p "$(dirname "$DEST")"
if [ -f "$DEST" ] && [ "$(stat -f%z "$DEST")" -gt 10000000 ]; then
  echo "Gadget already present: $DEST"
else
  TMP="$(mktemp -d)"
  echo "Downloading Frida Gadget ${VERSION}..."
  curl -L --fail --retry 3 -o "$TMP/gadget.dylib.xz" "$URL"
  xz -d "$TMP/gadget.dylib.xz"
  cp "$TMP/gadget.dylib" "$DEST"
  rm -rf "$TMP"
fi
chmod +x "$DEST"
/usr/bin/lipo -info "$DEST"
/usr/bin/codesign -f -s - --timestamp=none "$DEST" 2>/dev/null || true
echo "sha256: $(shasum -a 256 "$DEST" | awk '{print $1}')"
echo "Frida Gadget ready: $DEST"
