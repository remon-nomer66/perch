#!/bin/sh
set -eu

# Builds a drag-to-Applications disk image from an already packaged Perch.app.
#
# The window layout (background, icon positions) is written by asking Finder to
# arrange the mounted staging volume, which bakes a .DS_Store into the image. When
# Finder cannot be scripted (no Automation grant in this session), the image is
# still produced — it just opens with Finder's default look; the Applications
# symlink keeps the install gesture obvious either way.
#
# Usage: tools/make_dmg.sh [app-path] [output.dmg]

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app=${1:-"$project_dir/.build/Perch.app"}
out=${2:-"$project_dir/.build/Perch.dmg"}
volume="Perch"
background="$project_dir/Support/dmg-background.png"

[ -d "$app" ] || { echo "app not found: $app" >&2; exit 1; }

staging=$(mktemp -d)
rw_dmg="$staging/rw.dmg"
trap 'hdiutil detach "$mount" >/dev/null 2>&1 || true; rm -rf "$staging"' EXIT

mkdir "$staging/root"
cp -R "$app" "$staging/root/"
ln -s /Applications "$staging/root/Applications"
if [ -f "$background" ]; then
    mkdir "$staging/root/.background"
    cp "$background" "$staging/root/.background/background.png"
fi

# Read-write first so Finder can lay the window out; converted (compressed,
# read-only) afterwards, which is the shape users download.
hdiutil create -quiet -srcfolder "$staging/root" -volname "$volume" \
    -fs HFS+ -format UDRW "$rw_dmg"
mount="/Volumes/$volume"
hdiutil attach -quiet "$rw_dmg"

osascript > /dev/null 2>&1 <<EOS || echo "note: Finder styling skipped (no Automation grant); plain layout kept." >&2
tell application "Finder"
  tell disk "$volume"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, 800, 560}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 110
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Perch.app" of container window to {150, 185}
    set position of item "Applications" of container window to {450, 185}
    -- The dot entries only ever show for people running Finder with hidden files
    -- on; parked outside the window so even they get a clean layout.
    try
      set position of item ".background" of container window to {150, 700}
    end try
    try
      set position of item ".fseventsd" of container window to {450, 700}
    end try
    update without registering applications
    delay 2
    close
  end tell
end tell
EOS

# Give Finder a beat to flush the .DS_Store it just wrote before the volume goes
# away; detaching too early loses the layout.
sync
sleep 2

hdiutil detach -quiet "$mount"
rm -f "$out"
hdiutil convert -quiet "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$out"
echo "$out"
