#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
destination="${1:-$PWD/build}"
mkdir -p "$destination"
destination="${destination:A}"
build_tmp="$(mktemp -d "$destination/.gridnote-build.XXXXXXXX")"
trap 'rm -rf "$build_tmp"' EXIT
bundle="$build_tmp/Gridnote.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$build_tmp/Gridnote.iconset"
cp web/guide.html "$bundle/Contents/Resources/"
mkdir -p "$bundle/Contents/Resources/assets"
cp web/assets/icon-192.png "$bundle/Contents/Resources/assets/"
cp web/{launcher.html,launcher.css,launcher.js} "$bundle/Contents/Resources/"
cp web/solver.js "$bundle/Contents/Resources/solver.js"
cp scripts/Info.plist "$bundle/Contents/Info.plist"
arch="${GRIDNOTE_ARCH:-$(uname -m)}"
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported Mac architecture" >&2; exit 1 ;; esac
go_arch="$arch"
[[ "$go_arch" == x86_64 ]] && go_arch=amd64
(cd Desktop && GOOS=darwin GOARCH="$go_arch" CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$bundle/Contents/MacOS/GridnoteChatGPT" ./chatgpt)
python3 scripts/account_notices.py "$bundle/Contents/Resources/licenses"
codesign --force --sign - "$bundle/Contents/MacOS/GridnoteChatGPT"
swiftc -swift-version 5 -O -target "${arch}-apple-macos13.0" Sources/*.swift -o "$bundle/Contents/MacOS/Gridnote"
swiftc Sources/Chrome.swift scripts/Icon.swift -o "$build_tmp/icon"
"$build_tmp/icon" "$build_tmp/Gridnote.iconset"
iconutil -c icns "$build_tmp/Gridnote.iconset" -o "$bundle/Contents/Resources/Gridnote.icns"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
# Replace the bundle as a unit so upgrades also remove retired resources.
python3 - "$bundle" "$destination/Gridnote.app" <<'PYTHON'
import ctypes
import os
import plistlib
import sys
from pathlib import Path

built, target = map(Path, sys.argv[1:])
if target.is_symlink():
    raise SystemExit("Choose a build folder without a linked Gridnote.app.")
if target.exists():
    with (target / "Contents/Info.plist").open("rb") as info:
        if plistlib.load(info).get("CFBundleIdentifier") != "app.gridnote.notebook.mac":
            raise SystemExit("The existing bundle is not Gridnote.")
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.renamex_np(os.fsencode(built), os.fsencode(target), 2):  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
else:
    built.rename(target)
PYTHON
