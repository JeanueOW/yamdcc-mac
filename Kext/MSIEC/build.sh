#!/bin/bash
# Build the MSIEC kext with only the Command Line Tools installed.
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
KHEADERS="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
ARCH="${ARCH:-$(uname -m)}"
if [[ "$ARCH" != x86_64 ]]; then
	echo "MSIEC requires x86_64 (got $ARCH)" >&2
	exit 1
fi
CXX="${CXX:-clang++}"
CC="${CC:-clang}"

FLAGS=(
	-arch "$ARCH"
	-mkernel
	-fapple-kext
	-fno-builtin
	-fno-common
	-fno-exceptions
	-fno-rtti
	-fno-stack-protector
	-nostdinc++
	-DKERNEL
	-DKERNEL_PRIVATE
	-DDRIVER_PRIVATE
	-DAPPLE
	-DNeXT
	-I"$KHEADERS"
	-I"$SDK/usr/include"
	-O2
	-Wall
	-Wno-unused-parameter
)

# C flags: same kernel environment, but -fapple-kext/-nostdinc++ are C++ only.
CFLAGS_C=(
	-arch "$ARCH"
	-mkernel
	-fno-builtin
	-fno-common
	-fno-stack-protector
	-DKERNEL
	-DKERNEL_PRIVATE
	-DDRIVER_PRIVATE
	-DAPPLE
	-DNeXT
	-I"$KHEADERS"
	-I"$SDK/usr/include"
	-O2
	-Wall
	-Wno-unused-parameter
)

echo "==> Compiling MSIECMatch.cpp ($ARCH, read-only ACPI probe)"
"$CXX" "${FLAGS[@]}" -c MSIECMatch.cpp -o MSIECMatch.o

echo "==> Compiling MSIECInfo.c (kmod_info)"
"$CC" "${CFLAGS_C[@]}" -c MSIECInfo.c -o MSIECInfo.o

echo "==> Linking kext"
"$CXX" -arch "$ARCH" -mkernel -nostdlib -r -Wl,-kext MSIECMatch.o MSIECInfo.o -o MSIEC
# OpenCore needs the module metadata even if the Mach-O links without it.
nm -gU MSIEC | grep -E ' [dD] _kmod_info$' || {
	echo "Missing _kmod_info in MSIEC" >&2
	exit 1
}

rm -rf MSIEC.kext
mkdir -p MSIEC.kext/Contents/MacOS
mkdir -p MSIEC.kext/Contents/Resources
cp MSIEC-ECCTL.aml MSIEC.kext/Contents/Resources/MSIEC-ECCTL.aml
cp Info.plist MSIEC.kext/Contents/Info.plist
cp MSIEC MSIEC.kext/Contents/MacOS/MSIEC
chmod -R 755 MSIEC.kext

echo "==> Verifying baked helper hash"
python3 - <<'EOF'
import re, sys
src = open("MSIECMatch.cpp").read()
want = re.search(r"kHelperFNV = (0x[0-9A-Fa-f]+)ULL", src).group(1)
length = re.search(r"kHelperLength = (\d+)", src).group(1)
aml = open("MSIEC-ECCTL.aml", "rb").read()
h = 0xCBF29CE484222325
for b in aml:
    h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
if len(aml) != int(length) or f"0x{h:016X}" != want:
    sys.exit(f"AML hash mismatch: {len(aml)} {h:#x} vs baked {length} {want}")
print(f"helper AML {len(aml)} bytes, FNV {h:#x} matches driver")
EOF

echo "==> Ad-hoc signing"
codesign --force --sign - MSIEC.kext

echo "==> Verifying bundle (static checks only)"
plutil -lint MSIEC.kext/Contents/Info.plist
codesign --verify --strict MSIEC.kext

echo "Built: $(pwd)/MSIEC.kext"
