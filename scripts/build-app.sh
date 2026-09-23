#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
countdown_developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -x "$countdown_developer_dir/usr/bin/xcodebuild" ]; then
    echo "Building the native widget requires Xcode. Install Xcode or set DEVELOPER_DIR to its Contents/Developer folder." >&2
    exit 1
fi

countdown_build_root=$(mktemp -d "${TMPDIR:-/tmp}/countdown-build.XXXXXX")
trap 'rm -rf "$countdown_build_root"' EXIT
# Keep Xcode's coordinated project reads away from managed Documents folders.
for source in Countdown.xcodeproj Sources Widgets Build Assets; do
    ditto "$project_dir/$source" "$countdown_build_root/$source"
done

DEVELOPER_DIR="$countdown_developer_dir" xcodebuild \
    -project "$countdown_build_root/Countdown.xcodeproj" -scheme Countdown -configuration Release \
    -derivedDataPath "$countdown_build_root/DerivedData" -quiet \
    CODE_SIGN_IDENTITY="${COUNTDOWN_SIGN_IDENTITY:--}" build

countdown_output_dir="${COUNTDOWN_OUTPUT_DIR:-$project_dir/dist}"
app="$countdown_output_dir/Countdown Menu Bar.app"
mkdir -p "$countdown_output_dir"
countdown_product="$countdown_build_root/DerivedData/Build/Products/Release/Countdown Menu Bar.app"
ditto "$countdown_product" "$app"
# Finder/file-provider metadata can be added while copying into Documents.
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app" 2>/dev/null || true
codesign --verify --deep --strict "$app"
if [ "${COUNTDOWN_REGISTER_APP:-1}" = 1 ]; then
    countdown_lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
    "$countdown_lsregister" -u "$countdown_product" || true
    "$countdown_lsregister" -f "$app"
fi
echo "Built $app (includes Countdown Events widget)"
