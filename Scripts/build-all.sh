#!/bin/bash
# Build everything: kext, app bundle and CLI.
set -euo pipefail
cd "$(dirname "$0")/.."
./Kext/MSIEC/build.sh
./Scripts/build-app.sh
echo
echo "All artifacts:"
echo "  Kext/MSIEC/MSIEC.kext"
echo "  build/YAMDCC.app"
echo "  .build/release/yamdcc (CLI)"
