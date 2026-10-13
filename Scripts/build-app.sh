#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
configuration="${CONFIGURATION:-release}"
architectures="${ARCHS:-arm64 x86_64}"
app="$PWD/dist/Yandex Disk Downloader.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
binaries=()
for architecture in $architectures; do
    swift build -c "$configuration" --arch "$architecture" --cache-path "$PWD/.build/cache" --disable-sandbox
    binary_path=$(swift build -c "$configuration" --arch "$architecture" --cache-path "$PWD/.build/cache" --disable-sandbox --show-bin-path)
    binaries+=("$binary_path/YandexDiskDownloader")
done
if [ "${#binaries[@]}" -gt 1 ]; then
    lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/YandexDiskDownloader"
else
    cp "${binaries[0]}" "$app/Contents/MacOS/YandexDiskDownloader"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"; fi
# Local builds use ad-hoc signing; a paid account is not needed.
# Sandboxed builds are optional: SANDBOX=1 ./Scripts/build-app.sh.
if [ "${SANDBOX:-0}" = 1 ]; then
    codesign --force --sign - --entitlements Resources/YandexDiskDownloader.entitlements "$app"
else
    codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"
echo "Built: $app"
