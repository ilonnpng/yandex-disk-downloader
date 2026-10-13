#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
if [ -d "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]; then
    swift test --cache-path "$PWD/.build/cache" --disable-sandbox
else
    frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
    support="$(xcode-select -p)/Library/Developer/usr/lib"
    swift test --cache-path "$PWD/.build/cache" --disable-sandbox --disable-xctest -Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$support"
fi
