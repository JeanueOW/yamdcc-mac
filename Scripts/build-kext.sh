#!/bin/bash
# Build the MSIEC kernel extension.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ./Kext/MSIEC/build.sh
