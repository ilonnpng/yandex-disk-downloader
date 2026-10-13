#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="dist/Yandex Disk Downloader.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [ -n "${RELEASE_TAG:-}" ]; then
    test "$RELEASE_TAG" = "v$version"
fi
codesign --verify --strict "$app"
lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/YandexDiskDownloader"
archive="YandexDiskDownloader-$version-macOS-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "dist/$archive"
(cd dist && shasum -a256 "$archive" > SHA256SUMS.txt)
commit=$(git rev-parse HEAD)
build_url="local build"
if [ -n "${GITHUB_RUN_ID:-}" ]; then
    build_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
fi
cat > dist/BUILD_INFO.txt <<EOF
Yandex Disk Downloader $version
Source commit: $commit
Architectures: arm64, x86_64
Build: $build_url
Signing: ad-hoc; not Developer ID signed or Apple notarized.
Verify archive integrity with SHA256SUMS.txt.
GitHub release builds also publish a build-provenance attestation.
EOF
echo "Packaged: dist/$archive"
