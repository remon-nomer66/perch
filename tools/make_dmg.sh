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
#
# Environment (same names package_app.sh uses, so one export serves both):
#   PERCH_SIGN_IDENTITY   codesign identity for the finished image. Unset leaves the
#                         image unsigned, which is what the local flow wants.
#   PERCH_NOTARY_PROFILE  A `notarytool store-credentials` Keychain profile name.
#                         With a real identity, the image is submitted for
#                         notarization and stapled.
#
# Why the image and not just the app: the download that Gatekeeper judges is the
# .dmg. An app notarized inside an unsigned image still makes the first open show
# "Apple could not verify…", because the quarantined thing the user double-clicks
# is the image. Signing and stapling the image is what removes the warning.
#
# Neither variable holds a secret. The first is a certificate's *name*, the second
# a Keychain profile's *name*; the private key and the App Store Connect
# credentials never leave the Keychain, so nothing here belongs in a file.

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app=${1:-"$project_dir/.build/Perch.app"}
out=${2:-"$project_dir/.build/Perch.dmg"}
volume="Perch"
background="$project_dir/Support/dmg-background.png"

[ -d "$app" ] || { echo "app not found: $app" >&2; exit 1; }

staging=$(mktemp -d)
rw_dmg="$staging/rw.dmg"
mount=""
trap 'if [ -n "$mount" ]; then hdiutil detach "$mount" >/dev/null 2>&1 || true; fi; rm -rf "$staging"' EXIT

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

# Where it actually landed, asked rather than assumed. `/Volumes/Perch` is only
# free the first time: a stale mount — or the released image the user happens to
# have open — takes the name, and this one becomes "Perch 1". Assuming the name
# made the script style and then unmount *the other volume*, and fail with no
# message because -quiet swallowed it.
mount=$(hdiutil attach "$rw_dmg" | sed -n 's|.*	\(/Volumes/.*\)$|\1|p' | tail -1)
[ -n "$mount" ] || { echo "could not determine the mount point" >&2; exit 1; }
mounted_volume=$(basename "$mount")

osascript > /dev/null 2>&1 <<EOS || echo "note: Finder styling skipped (no Automation grant); plain layout kept." >&2
tell application "Finder"
  tell disk "$mounted_volume"
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

# Finder can hold the volume for a moment after closing its window, so a busy
# detach is ordinary — retry, then force. Failing here used to end the script with
# no message at all: `set -e` on a `-quiet` detach exits 1 in silence.
detached=0
attempt=0
while [ "$attempt" -lt 5 ]; do
    if hdiutil detach "$mount" >/dev/null 2>&1; then
        detached=1
        break
    fi
    attempt=$((attempt + 1))
    sleep 1
done
if [ "$detached" -ne 1 ] && ! hdiutil detach -force "$mount" >/dev/null 2>&1; then
    echo "could not unmount $mount" >&2
    exit 1
fi
mount=""

rm -f "$out"
hdiutil convert -quiet "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$out"

# Sign, notarize, staple — in that order, and only when the credentials are there.
# The compressed image is the artefact all three act on, so this has to come after
# the convert: signing the read-write image would be discarded by it.
identity=${PERCH_SIGN_IDENTITY:-}
if [ -n "$identity" ] && [ "$identity" != "-" ]; then
    # A secure timestamp is required for notarization and harmless without it.
    codesign --force --sign "$identity" --timestamp "$out"
    codesign --verify --strict "$out"

    if [ -n "${PERCH_NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$out" \
            --keychain-profile "$PERCH_NOTARY_PROFILE" --wait
        # Stapling attaches the ticket to the image itself, so a Mac that is offline
        # on first open still sees a notarized download.
        xcrun stapler staple "$out"
        # `-t open --context context:primary-signature` is how Gatekeeper judges a
        # downloaded disk image; `-t execute` would ask the wrong question of it.
        if ! spctl --assess -vv --type open \
            --context context:primary-signature "$out"; then
            echo "warning: Gatekeeper rejected the image; it may still be" >&2
            echo "warning: propagating the notarization ticket." >&2
        fi
    else
        echo "note: PERCH_NOTARY_PROFILE unset; the image is signed but not" >&2
        echo "note: notarized, so a download still warns on first open." >&2
    fi
else
    echo "note: PERCH_SIGN_IDENTITY unset; the image is unsigned. Fine locally;" >&2
    echo "note: a downloaded copy will be refused by Gatekeeper." >&2
fi

echo "$out"
