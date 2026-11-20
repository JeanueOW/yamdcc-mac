#!/bin/bash
# Report injection, kernel loading, service publication and EC access separately.
set -u
cd "$(dirname "$0")/.." || exit 1

esp="${1:-/Volumes/1401}"
boot=$(sysctl -n kern.boottime)
printf '== 本次 macOS 启动 ==\n%s\n' "$boot"

printf '\n== OpenCore 注入（最近一份日志，不一定属于本次启动） ==\n'
shopt -s nullglob
logs=("$esp"/opencore-*.txt)
if ((${#logs[@]})); then
  latest="${logs[${#logs[@]} - 1]}"
  printf '%s\n' "$latest"
  grep -aF 'OC: Prelinked injection MSIEC.kext ' "$latest" | tr -d '\r' || :
else
  printf '未找到 %s 上的 OpenCore 日志。可传入实际 EFI 卷的路径。\n' "$esp"
fi

printf '\n== 已加载的 kext ==\n'
if loaded=$(kmutil showloaded --list-only 2>/dev/null); then
  printf '%s\n' "$loaded" | grep -F 'com.yamdcc.MSIEC ' || echo '未加载 com.yamdcc.MSIEC'
else
  echo '无法获取 kmutil 列表'
fi

printf '\n== IOService 匹配 ==\n'
service=$(ioreg -p IOService -r -d 1 -c com_yamdcc_MSIEC -w0 -l)
if [[ "$service" == *'<class com_yamdcc_MSIEC,'* ]]; then
  printf '%s\n' "$service" | grep -E '<class com_yamdcc_MSIEC,|"(MSIECAccess|MSIECProbeABI|IONameMatched|IOProviderClass)" ='
else
  echo '未找到 com_yamdcc_MSIEC 服务'
fi

printf '\n== 本次启动的 MSIEC 内核日志 ==\n'
log_args=(--last 15m)
if [[ "$boot" =~ sec[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
  since=$(date -r "${BASH_REMATCH[1]}" '+%Y-%m-%d %H:%M:%S')
  log_args=(--start "$since")
fi
log show "${log_args[@]}" --style compact --predicate \
  'process == "kernel" AND (eventMessage CONTAINS[c] "MSIEC:" OR eventMessage CONTAINS[c] "com.yamdcc.MSIEC" OR eventMessage CONTAINS[c] "com_yamdcc_MSIEC")' 2>/dev/null | tail -15

printf '\n== 真实 EC ==\n'
case "$service" in
  *'"MSIECAccess" = "match-only"'*)
    echo '服务已匹配。此诊断版不读写 EC；没有真实风扇数据。'
    ;;
  *'"MSIECAccess" = "acpi-probe"'*)
    echo '服务已匹配。诊断脚本不会自动访问 EC。'
    if ! grep -Eq '"MSIECProbeABI" = 2[[:space:]]*$' <<< "$service"; then
      echo '诊断接口需要 MSIEC 1.1.0（ABI 2）；没有运行采样。'
    elif [[ -x .build/release/yamdcc ]]; then
      printf '手动执行单次只读采样：sudo %q ec probe\n' "$PWD/.build/release/yamdcc"
    else
      echo '未找到 release CLI；请先运行 ./Scripts/build-app.sh。'
    fi
    ;;
  *'"MSIECAccess" = "coordinated"'*)
    if [[ ! -x .build/release/yamdcc ]]; then
      echo '未找到 release CLI；请先运行 ./Scripts/build-app.sh。' >&2
      exit 1
    fi
    exec .build/release/yamdcc --require-real status
    ;;
  *)
    echo '没有可用的真实 EC 后端；未运行模拟 EC。'
    exit 1
    ;;
esac
