#!/bin/bash
# Swift 6 tests without a running driver or a connection to the EC.
set -euo pipefail
cd "$(dirname "$0")/.."

flags=()
dev="$(xcode-select -p)/Library/Developer"
# Standalone Command Line Tools may omit the test frameworks from SwiftPM's search paths.
if [[ -d "$dev/Frameworks/Testing.framework" ]]; then
    flags+=(-Xswiftc -F -Xswiftc "$dev/Frameworks"
            -Xlinker -rpath -Xlinker "$dev/Frameworks"
            -Xlinker -rpath -Xlinker "$dev/usr/lib")
fi
swift test --disable-xctest ${flags[@]+"${flags[@]}"}
