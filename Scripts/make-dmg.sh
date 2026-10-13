#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test -d "dist/Yandex Disk Downloader.app"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "dist/Yandex Disk Downloader.app" "$stage/Yandex Disk Downloader.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname 'Yandex Disk Downloader' -srcfolder "$stage" -ov -format UDZO dist/YandexDiskDownloader.dmg
