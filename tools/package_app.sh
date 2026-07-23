#!/bin/sh
set -eu

# Builds Perch.app and signs it with a stable identity.
#
# Usage:
#   tools/package_app.sh            debug build (default; what control-lock.sh runs)
#   tools/package_app.sh release    release build; the app icon becomes mandatory
#
# Environment:
#   PERCH_SIGN_IDENTITY   codesign identity. Unset signs ad-hoc. TCC grants are tied
#                         to the signing identity, so an ad-hoc signature that changes
#                         on every build makes macOS re-prompt for Bluetooth and Apple
#                         Events each time. For daily use, set a self-signed
#                         certificate created once in Keychain Access; for
#                         distribution, a "Developer ID Application" identity.
#   PERCH_VERSION         CFBundleShortVersionString to stamp into the app.
#   PERCH_BUILD           CFBundleVersion to stamp into the app.
#                         When unset, a release build falls back to `git describe`
#                         and the commit count; a debug build keeps the values
#                         already in Support/Info.plist.
#   PERCH_NOTARY_PROFILE  A `notarytool store-credentials` keychain profile name.
#                         When set on a release build signed with a Developer ID
#                         identity, the app is submitted for notarization and
#                         stapled. Unset skips notarization (local self-signed flow).

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${1:-debug}

case "$configuration" in
    debug|release) ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

build_dir="$project_dir/.build/$configuration"
app_dir="$project_dir/.build/Perch.app"
identity=${PERCH_SIGN_IDENTITY:-}

swift build --package-path "$project_dir" -c "$configuration" --product Perch

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
install -m 0755 "$build_dir/Perch" "$app_dir/Contents/MacOS/Perch"
install -m 0644 "$project_dir/Support/Info.plist" "$app_dir/Contents/Info.plist"

# Version stamp. Explicit env vars win; a release build falls back to git metadata;
# a debug build keeps whatever Support/Info.plist already carries.
version=${PERCH_VERSION:-}
build_number=${PERCH_BUILD:-}
if [ "$configuration" = "release" ]; then
    if [ -z "$version" ]; then
        version=$(git -C "$project_dir" describe --tags 2>/dev/null | sed 's/^v//' || true)
    fi
    if [ -z "$build_number" ]; then
        build_number=$(git -C "$project_dir" rev-list --count HEAD 2>/dev/null || true)
    fi
fi
if [ -n "$version" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
        "$app_dir/Contents/Info.plist"
fi
if [ -n "$build_number" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" \
        "$app_dir/Contents/Info.plist"
fi

# SwiftPM resource bundle (menu bar icons). Bundle.module looks for it in
# Contents/Resources and traps when it is missing, so it must ride along. Everything
# under Contents/Resources has to land before codesign seals the bundle.
mkdir -p "$app_dir/Contents/Resources"
cp -R "$build_dir/Perch_Perch.bundle" "$app_dir/Contents/Resources/"

# Localized permission strings. Info.plist holds the English defaults; each .lproj
# overrides them for its language.
for loc in en ja; do
    strings_src="$project_dir/Support/$loc.lproj/InfoPlist.strings"
    if [ -f "$strings_src" ]; then
        mkdir -p "$app_dir/Contents/Resources/$loc.lproj"
        install -m 0644 "$strings_src" \
            "$app_dir/Contents/Resources/$loc.lproj/InfoPlist.strings"
    else
        echo "warning: $strings_src missing; permission text stays unlocalized." >&2
    fi
done

# License texts ride along so a distributed .app carries its own attribution
# (AGPL-3.0, third-party notices, trademark policy).
for doc in LICENSE THIRD_PARTY_NOTICES.md TRADEMARK.md; do
    if [ -f "$project_dir/$doc" ]; then
        install -m 0644 "$project_dir/$doc" "$app_dir/Contents/Resources/$doc"
    else
        echo "warning: $doc not found; building without it." >&2
    fi
done

# App icon: compile the Icon Composer document into the bundle. actool emits the
# layered Liquid Glass icon (Assets.car) that macOS 26 renders, plus a flattened
# .icns for older systems. The Info.plist already names it (CFBundleIconName=Appicon).
icon_ok=0
icon_doc="$project_dir/Appicon.icon"
if [ -d "$icon_doc" ] && command -v xcrun >/dev/null 2>&1; then
    actool_log="$build_dir/actool.log"
    if xcrun actool "$icon_doc" \
        --compile "$app_dir/Contents/Resources" \
        --app-icon Appicon \
        --output-partial-info-plist "$build_dir/appicon-partial.plist" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --errors > "$actool_log" 2>&1; then
        icon_ok=1
    else
        echo "warning: app icon compilation failed; actool output follows." >&2
        cat "$actool_log" >&2
    fi
else
    echo "warning: Appicon.icon or actool missing." >&2
fi
if [ "$icon_ok" -ne 1 ]; then
    if [ "$configuration" = "release" ]; then
        echo "error: a release build requires the app icon; aborting." >&2
        exit 1
    fi
    echo "warning: building without an icon." >&2
fi

if [ -z "$identity" ]; then
    echo "PERCH_SIGN_IDENTITY is unset; signing ad-hoc." >&2
    echo "Permission prompts will reappear after every rebuild." >&2
    identity="-"
fi

# Notarization needs a secure timestamp; the extra network round-trip is skipped
# on the everyday self-signed flow.
timestamp_flag=""
if [ -n "${PERCH_NOTARY_PROFILE:-}" ] && [ "$identity" != "-" ]; then
    timestamp_flag="--timestamp"
fi

codesign --force \
    --sign "$identity" \
    --options runtime \
    $timestamp_flag \
    --entitlements "$project_dir/Support/Perch.entitlements" \
    "$app_dir"

codesign --verify --strict "$app_dir"

# Optional notarization: only when credentials are provided, on a release build
# signed with a real (Developer ID) identity. Anything else keeps the plain
# self-signed result so the local flow never breaks.
if [ -n "${PERCH_NOTARY_PROFILE:-}" ]; then
    if [ "$configuration" != "release" ] || [ "$identity" = "-" ]; then
        echo "warning: PERCH_NOTARY_PROFILE is set but this is not a release build" >&2
        echo "warning: with a signing identity; skipping notarization." >&2
    else
        archive="$project_dir/.build/Perch-notarize.zip"
        rm -f "$archive"
        ditto -c -k --keepParent "$app_dir" "$archive"
        xcrun notarytool submit "$archive" \
            --keychain-profile "$PERCH_NOTARY_PROFILE" --wait
        xcrun stapler staple "$app_dir"
        codesign --verify --strict "$app_dir"
        if ! spctl --assess --type execute "$app_dir"; then
            echo "warning: spctl assessment failed; Gatekeeper may still be" >&2
            echo "warning: propagating the notarization ticket." >&2
        fi
    fi
fi

echo "$app_dir"
