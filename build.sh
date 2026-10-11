#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$#" -le 1 ] || { echo 'Usage: sh build.sh [output-directory]' >&2; exit 64; }
output=${1:-"$root/build"}
mkdir -p "$output"
output=$(CDPATH= cd -- "$output" && pwd)
app="$output/MacUnlock.app"
mkdir -p "$app/Contents/MacOS"
cd "$root"
swiftc -O src/Policy.swift src/Native.swift src/main.swift -o "$app/Contents/MacOS/mac-unlock"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.MacUnlock</string>
<key>CFBundleName</key><string>MacUnlock</string>
<key>CFBundleExecutable</key><string>mac-unlock</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier com.example.MacUnlock --timestamp=none "$app"
codesign --verify --deep --strict "$app"
