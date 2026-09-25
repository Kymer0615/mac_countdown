#!/bin/sh
# Build and verify an immutable, universal release archive. Does not publish.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Build/App-Info.plist)
widget_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Build/Widget-Info.plist)
if [ "$version" != "$widget_version" ]; then
    echo 'App and widget versions must match.' >&2
    exit 1
fi
if [ "$#" -ne 1 ] || [ "$1" != "v$version" ]; then
    echo "Usage: sh scripts/package-release.sh v$version" >&2
    exit 1
fi
archive="$project_dir/dist/Countdown-Menu-Bar-$version-universal.zip"
if [ -e "$archive" ]; then
    echo "Archive already exists: $archive. Move it aside before rebuilding." >&2
    exit 1
fi
sh scripts/check.sh
release_tmp=$(mktemp -d "${TMPDIR:-/tmp}/countdown-release.XXXXXX")
trap 'rm -rf "$release_tmp"' EXIT
COUNTDOWN_REGISTER_APP=0 COUNTDOWN_OUTPUT_DIR="$release_tmp/product" sh scripts/build-app.sh
app="$release_tmp/product/Countdown Menu Bar.app"
widget="$app/Contents/PlugIns/CountdownEventsWidget.appex"
for bundle in "$app" "$widget"; do
    test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$bundle/Contents/Info.plist")" = "$version"
    executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$bundle/Contents/Info.plist")
    architectures=$(lipo -archs "$bundle/Contents/MacOS/$executable")
    for required_arch in arm64 x86_64; do
        case " $architectures " in
            *" $required_arch "*) ;;
            *) echo "Missing $required_arch in $bundle" >&2; exit 1 ;;
        esac
    done
    codesign --verify --deep --strict "$bundle"
done
# Without this hardened-runtime entitlement, Calendar access is denied silently.
codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q 'com.apple.security.personal-information.calendars' || {
    echo 'Missing Calendar entitlement in the app signature.' >&2
    exit 1
}
ditto -c -k --keepParent "$app" "$release_tmp/release.zip"
ditto -x -k "$release_tmp/release.zip" "$release_tmp/verify"
codesign --verify --deep --strict "$release_tmp/verify/Countdown Menu Bar.app"
mkdir -p "$project_dir/dist"
mv "$release_tmp/release.zip" "$archive"
cd "$project_dir/dist"
shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256"
cat "$(basename "$archive").sha256"
