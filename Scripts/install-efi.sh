#!/bin/bash
# Install MSIEC + its EC helper SSDT into an OpenCore ESP, with backups.
# Usage: Scripts/install-efi.sh [/Volumes/1401]
set -euo pipefail
cd "$(dirname "$0")/.."

ESP="${1:-/Volumes/1401}"
OC="$ESP/EFI/OC"
KEXT="Kext/MSIEC/MSIEC.kext"
AML="Kext/MSIEC/MSIEC-ECCTL.aml"
CONFIG="$OC/config.plist"

[[ -d "$OC" ]] || { echo "找不到 $OC" >&2; exit 1; }
[[ -d "$KEXT" ]] || { echo "先运行 Kext/MSIEC/build.sh" >&2; exit 1; }
[[ -f "$AML" ]] || { echo "先运行 python3 Kext/MSIEC/gen-ecctl.py" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="build/efi-backups/ecctl-$STAMP.$$"
mkdir -p "$BACKUP"
cp "$CONFIG" "$BACKUP/config.plist"
[[ -d "$OC/Kexts/MSIEC.kext" ]] && cp -R "$OC/Kexts/MSIEC.kext" "$BACKUP/MSIEC.kext"
[[ -f "$OC/ACPI/MSIEC-ECCTL.aml" ]] && cp "$OC/ACPI/MSIEC-ECCTL.aml" "$BACKUP/MSIEC-ECCTL.aml"
echo "备份: $BACKUP"

# Stage, verify, then swap in.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$KEXT" "$STAGE/MSIEC.kext"
cmp -s "$STAGE/MSIEC.kext/Contents/MacOS/MSIEC" "$KEXT/Contents/MacOS/MSIEC"
codesign --verify --strict "$STAGE/MSIEC.kext"
cp "$AML" "$STAGE/MSIEC-ECCTL.aml"

rm -rf "$OC/Kexts/MSIEC.kext"
cp -R "$STAGE/MSIEC.kext" "$OC/Kexts/MSIEC.kext"
mkdir -p "$OC/ACPI"
cp "$STAGE/MSIEC-ECCTL.aml" "$OC/ACPI/MSIEC-ECCTL.aml"
xattr -cr "$OC/Kexts/MSIEC.kext" 2>/dev/null || true

python3 - "$CONFIG" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as handle:
    config = plistlib.load(handle)

acpi = config.setdefault("ACPI", {}).setdefault("Add", [])
entry = {
    "Comment": "YAMDCC EC control helper (MSIEC)",
    "Enabled": True,
    "Path": "MSIEC-ECCTL.aml",
}
acpi[:] = [item for item in acpi if item.get("Path") != "MSIEC-ECCTL.aml"]
acpi.append(entry)

kern = config.setdefault("Kernel", {}).setdefault("Add", [])
kext = {
    "Arch": "x86_64",
    "BundlePath": "MSIEC.kext",
    "Comment": "MSIEC - YAMDCC EC access (com.yamdcc.MSIEC)",
    "Enabled": True,
    "ExecutablePath": "Contents/MacOS/MSIEC",
    "MaxKernel": "",
    "MinKernel": "",
    "PlistPath": "Contents/Info.plist",
}
kern[:] = [item for item in kern if item.get("BundlePath") != "MSIEC.kext"]
kern.append(kext)

with open(path, "wb") as handle:
    plistlib.dump(config, handle, sort_keys=False)
print(f"config: {len(acpi)} ACPI entries, {len(kern)} kext entries")
PY

plutil -lint "$CONFIG" >/dev/null
shasum -a 256 "$CONFIG" | awk '{print "config sha256:", $1}'
shasum -a 256 "$OC/Kexts/MSIEC.kext/Contents/MacOS/MSIEC" "$OC/ACPI/MSIEC-ECCTL.aml"
echo "已安装 MSIEC 1.1.0 + MSIEC-ECCTL.aml 到 ${ESP}，重启后生效。"
