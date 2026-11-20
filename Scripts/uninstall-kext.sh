#!/bin/bash
# Unload and remove MSIEC.kext.
set -euo pipefail
sudo kmutil unload -p /Library/Extensions/MSIEC.kext 2>/dev/null || true
sudo rm -rf /Library/Extensions/MSIEC.kext
echo "已移除 MSIEC.kext"
