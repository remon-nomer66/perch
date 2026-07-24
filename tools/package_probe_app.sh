#!/bin/sh
set -eu

# Wraps the bose-probe binary in a minimal .app so it can be launched via
# LaunchServices (`open`). On macOS 26, classic-Bluetooth SDP/RFCOMM is refused for a
# process that was not launched that way — a bare CLI sees zero SDP records and every
# performSDPQuery times out — so hardware疎通 has to go through a bundle.
# See docs/rfcomm-transport-notes.md §4.
#
# Usage:
#   tools/package_probe_app.sh            # debug build, ad-hoc signed
#
# Environment:
#   PERCH_SIGN_IDENTITY   codesign identity. TCC (Bluetooth) grants are tied to the
#                         signing identity, so a stable self-signed cert avoids a fresh
#                         Bluetooth prompt on every rebuild; unset signs ad-hoc.

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$project_dir/.build/debug"
app_dir="$project_dir/.build/BoseProbe.app"
identity=${PERCH_SIGN_IDENTITY:-}

swift build --package-path "$project_dir" -c debug --product bose-probe

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
install -m 0755 "$build_dir/bose-probe" "$app_dir/Contents/MacOS/bose-probe"

# Minimal Info.plist. NSBluetoothAlwaysUsageDescription is required or macOS denies
# Bluetooth without a prompt. A distinct bundle id keeps its TCC grant separate from
# the shipping app's.
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>bose-probe</string>
	<key>CFBundleIdentifier</key>
	<string>dev.perch.bose-probe</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>BoseProbe</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>bose-probe reads the status of your connected Bose headphones over Bluetooth.</string>
</dict>
</plist>
PLIST

if [ -z "$identity" ]; then
    echo "PERCH_SIGN_IDENTITY is unset; signing ad-hoc (Bluetooth prompt will reappear on rebuild)." >&2
    identity="-"
fi

codesign --force --sign "$identity" --options runtime "$app_dir"
codesign --verify --strict "$app_dir"

echo "$app_dir"
