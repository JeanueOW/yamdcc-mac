# YAMDCC for macOS

MSI 笔记本风扇与 EC（嵌入式控制器）控制的 macOS 原生移植版本，参考
[Sparronator9999/YAMDCC](https://codeberg.org/Sparronator9999/YAMDCC) 的寄存器映射与
XML 配置格式，用 SwiftUI + 自定义 IOKit 内核扩展重新实现。

> MSIEC 1.1.0 已在本项目测试机上读取两路风扇数据，并通过 ACPI 字段写入风扇曲线。
> 只对核对过 DSDT 指纹的这台机器启用写入；其他机器保持只读或不可用，绝不回退到模拟数据。

## 功能

- **总览**：真实 CPU / GPU 温度、转速、占空比实时曲线（也可显式切到模拟）
- **真机采样**：导入单次只读诊断的 JSON，显示采样时间、温度、占空比和估算转速
- **风扇曲线**：7 点可拖拽曲线，独立编辑升 / 降阈值与转速，支持多配置文件
- **硬件设置**：充电上限、性能模式、风扇模式、键盘背光、Win / Fn 交换、全速模式
- **EC 监视器**：256 字节寄存器网格、单寄存器读写、整表读取
- **配置文件**：直接兼容 YAMDCC 的 v1（`YAMDCC_Config`）与 v2（`YamdccCfg`）XML，
  内置 19 个上游机型配置，可导入 / 导出 / 删除
- **菜单栏**：温度速览、全速开关、一键应用曲线
- **CLI**：`yamdcc list / status / apply / watch / ec probe [--json] / ...`

## 系统要求

- macOS 13 Ventura 或更新版本（在 macOS 26 Tahoe / x86_64 上开发测试）
- MSIEC 诊断驱动仅支持 x86_64，需要有 ACPI `PNP0C09` 设备的测试机（见下文）。
- 仅用命令行工具（Command Line Tools）即可构建，不需要完整 Xcode

## 构建

```bash
./Scripts/build-all.sh          # 生成 build/YAMDCC.app 与 Kext/MSIEC/MSIEC.kext
open build/YAMDCC.app           # 直接运行（无驱动时显示未连接，不显示模拟数据）
./Scripts/test-offline.sh       # 离线配置与采样格式测试（Swift 6，不访问 EC）
```

产物：

- `build/YAMDCC.app` — 主程序（含 `yamdcc-cli` 与内置配置）
- `Kext/MSIEC/MSIEC.kext` — EC 读写驱动（ACPI 字段中介）
- `Kext/MSIEC/MSIEC-ECCTL.aml` — 写入辅助 SSDT（由 `gen-ecctl.py` 生成，哈希内置于驱动）
- `.build/release/yamdcc` — 命令行工具

## 安装诊断内核扩展

MSIEC 匹配 ACPI 的 EC 设备（`IOACPIPlatformDevice` / `PNP0C09`），并发布
`com_yamdcc_MSIEC` 服务。1.0.1 仅验证匹配；1.0.3 验证路径、DSDT 指纹与
AppleACPIEC 就绪后读取 8 个固件预定义字段；1.1.0 增加白名单写入方法与
`MSIEC-ECCTL.aml` 哈希校验。1.0.3
改为在 ACPI 的 `EC` / `SCM0` 设备上按短名称读取，避免 1.0.2 的完整名称
被 macOS 拒绝。它不会替换 AppleACPIEC、注入新 AML、在启动时读取 EC 或直接访问 EC 端口。

### 方式 A：OpenCore 注入（黑苹果）

1. 把 `Kext/MSIEC/MSIEC.kext` 拷到 `EFI/OC/Kexts/`
2. 在 `config.plist` 的 `Kernel > Add` 末尾加入（`Enabled` 为 `true`）：

```xml
<dict>
    <key>Arch</key><string>x86_64</string>
    <key>BundlePath</key><string>MSIEC.kext</string>
    <key>Comment</key><string>MSIEC - YAMDCC read-only ACPI diagnostic</string>
    <key>Enabled</key><true/>
    <key>ExecutablePath</key><string>Contents/MacOS/MSIEC</string>
    <key>MaxKernel</key><string></string>
    <key>MinKernel</key><string></string>
    <key>PlistPath</key><string>Contents/Info.plist</string>
</dict>
```

3. 重启，然后运行 `./Scripts/check-kext.sh [EFI 卷路径]`。`Prelinked injection ... - Success`
   只表示 OpenCore 已注入；还应看到 `kmutil` 列出 `com.yamdcc.MSIEC (1.1.0)`。
   `MSIECAccess = coordinated` 表示辅助 SSDT 已就位、可读写；`acpi-probe` 表示只读，
   不等于已经读到 EC；`match-only` 表示没有可调用的探测接口。
   脚本在这两种模式下都不会访问 EC 或生成模拟值。
4. 回退：换回已备份的 `MSIEC.kext`，或禁用 `Kernel > Add` 中的 `MSIEC.kext` 条目，再重启。

### 方式 B：/Library/Extensions

```bash
sudo cp -R Kext/MSIEC/MSIEC.kext /Library/Extensions/
sudo chown -R root:wheel /Library/Extensions/MSIEC.kext
sudo kmutil load -p /Library/Extensions/MSIEC.kext
```

- 如果系统提示“无法验证开发者”，到 **系统设置 → 隐私与安全性** 允许后重启。
- 卸载：`sudo kmutil unload -p /Library/Extensions/MSIEC.kext && sudo rm -rf /Library/Extensions/MSIEC.kext`

> 构建产物为 ad-hoc 签名，macOS 可能拒绝直接加载。请勿为了运行此诊断版关闭系统安全保护。

## 使用

1. 未选择其他配置时，GUI 和 CLI 默认载入 [MSI Vector 16 HX A14VHG](https://codeberg.org/Sparronator9999/YAMDCC/src/branch/main/Configs/MSI-Vector-16-HX-A14VHG.xml)（Adam / KamykJr 的上游 XML，原样内置）。已有有效选择或 CLI 的 `--config PATH` 仍优先。载入配置不会写入 EC。
2. 载入机型配置并编辑风扇曲线；「应用」会通过 ACPI 字段写入真实 EC（需 MSIEC 1.1.0 + 辅助 SSDT）。
3. 如需查看真机读数，用下面的 `ec probe --json` 手动采样，在侧栏「真机采样」中导入桌面上的 JSON。App 不启动 `sudo`、不后台采集、不用模拟读数填补缺失项。导入数据不是实时值，文件来源未经 App 独立验证。

命令行示例：

```bash
.build/release/yamdcc --simulate status       # 模拟模式查看状态
.build/release/yamdcc --simulate apply        # 在模拟 EC 中应用配置
.build/release/yamdcc --require-real status   # 真机状态，不允许回退到模拟模式
sudo .build/release/yamdcc ec probe           # 单次真机只读诊断（JSON 采样）
sudo .build/release/yamdcc ec probe --json > "$HOME/Desktop/yamdcc-sample.json"
```

`ec probe` 不接受寄存器参数或 XML 配置，不修改 EC，也不启动轮询。它只读取固件已有的
CPU/GPU 温度、风扇占空比和转速计字段，输出原始字节和估算 RPM；若固件不匹配或读取
失败，会报告失败阶段，不输出采样 JSON，也不重试。未报告或超出合理范围的指标显示为「—」，
不是 0。转速是由两个字节的周期值换算的估计值，不代表校准读数。

## 配置文件

内置配置来自上游 `Configs/` 与 `Configs-V2/`，两者都支持：

- **v1**：寄存器布局写在 XML 里，适用于大量老机型
- **v2**：只描述曲线与策略，寄存器映射由内置布局（gen1 / gen2）决定

应用逻辑与上游一致：先写风扇模式，再逐点写曲线、升阈值与降阈值
（`OffsetDT` 时写入 `Up - Down`），最后写性能模式、全速位、充电上限、
键盘背光与 Win/Fn 交换。

## 已知限制

- 真机写入仅在 MSIEC 检测到内置哈希匹配的 `MSIEC-ECCTL.aml` 时启用；可用 `Scripts/install-efi.sh` 安装。
- 写入寄存器白名单固定（风扇曲线/阈值、性能/风扇模式、充电上限、背光、Win/Fn、全速），不支持任意偏移。
- 没有实现上游的“开机自启服务”、热键与自动更新。
- 单风扇 / 无键盘背光机型会自动隐藏对应控件。

## 许可

GPL-3.0-or-later，见 [LICENSE.md](LICENSE.md)。

寄存器映射、配置格式与部分文案来自 [YAMDCC](https://codeberg.org/Sparronator9999/YAMDCC)
（作者 Sparronator9999，GPL-3.0）。本项目为独立实现，与 MSI 官方无关。
