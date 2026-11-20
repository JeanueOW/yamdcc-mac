#!/bin/bash
# Install and load MSIEC.kext. Requires sudo and a relaxed SIP/AMFI policy.
set -euo pipefail
cd "$(dirname "$0")/.."

KEXT="Kext/MSIEC/MSIEC.kext"
DEST="/Library/Extensions/MSIEC.kext"

if [ ! -d "$KEXT" ]; then
	echo "找不到 $KEXT，请先运行 ./Kext/MSIEC/build.sh" >&2
	exit 1
fi

echo "==> 复制到 $DEST"
sudo rm -rf "$DEST"
sudo cp -R "$KEXT" "$DEST"
sudo chown -R root:wheel "$DEST"
sudo chmod -R 755 "$DEST"

echo "==> 加载内核扩展"
sudo kmutil load -p "$DEST" || {
	echo "加载失败。请确认："
	echo "  - 已关闭 SIP（至少允许未签名 kext）"
	echo "  - AMFI 已放行（黑苹果常用 AMFIPass）"
	echo "  - 在“系统设置 → 隐私与安全性”中允许了来自此开发者的软件"
	exit 1
}

echo "==> 验证"
ioreg -l -w 0 -r -c com_yamdcc_MSIEC | head -20 || true
echo "完成。现在运行 build/YAMDCC.app 即可连接真实 EC。"
