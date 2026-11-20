// SettingsView.swift
// Application preferences, driver installation help and diagnostics.

import SwiftUI
import AppKit
import YAMDCCKit

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    @State private var simulate = false
    @State private var pollInterval = 1.0
    @State private var applyOnLaunch = false
    @State private var showMenuBar = true

    var body: some View {
        Form {
            Section("EC 连接") {
                LabeledContent("后端") {
                    Text(state.backendInfo.backend)
                }
                LabeledContent("固件") {
                    Text(state.backendInfo.firmwareVersion.isEmpty
                         ? "—" : "\(state.backendInfo.firmwareVersion)  \(state.backendInfo.firmwareDate)")
                        .textSelection(.enabled)
                }
                Toggle("强制模拟模式", isOn: $simulate)
                    .onChange(of: simulate) { newValue in
                        state.settings.update { $0.forceSimulation = newValue }
                        state.connect()
                    }
                Button("重新连接") { state.connect() }
            }

            Section("监控") {
                HStack {
                    Text("采样间隔")
                    Slider(value: $pollInterval, in: 0.5...5, step: 0.5,
                           label: { EmptyView() })
                    Text(String(format: "%.1f 秒", pollInterval))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                .onChange(of: pollInterval) { newValue in
                    state.settings.update { $0.pollInterval = newValue }
                    state.monitor?.interval = newValue
                }
            }

            Section("启动") {
                Toggle("启动时自动应用上次的配置", isOn: $applyOnLaunch)
                    .onChange(of: applyOnLaunch) { newValue in
                        state.settings.update { $0.applyOnLaunch = newValue }
                    }
                Toggle("在菜单栏显示温度", isOn: $showMenuBar)
                    .onChange(of: showMenuBar) { newValue in
                        state.settings.update { $0.showMenuBarExtra = newValue }
                    }
            }

            Section("内核扩展") {
                VStack(alignment: .leading, spacing: 8) {
                    if state.backendInfo.isSimulated {
                        Text("当前没有连接到 MSIEC 驱动。真实控制需要安装并加载该内核扩展（需要关闭 SIP 或允许第三方 kext）。")
                            .font(.callout)
                    } else {
                        Text("MSIEC 已连接，可以直接读写 EC。")
                            .font(.callout)
                    }
                    Text("""
                    安装步骤：
                     1. 运行 Scripts/build-all.sh 生成 .app 与 MSIEC.kext
                     2. sudo cp -R Kext/MSIEC/MSIEC.kext /Library/Extensions/
                     3. sudo kmutil load -p /Library/Extensions/MSIEC.kext
                     4. 如被系统拦截，在“隐私与安全性”中允许，然后重启
                    """)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                    HStack {
                        Button("复制安装命令") {
                            let command = """
                            sudo cp -R "\(RepositoryPaths.kextPath)" /Library/Extensions/ && \
                            sudo kmutil load -p /Library/Extensions/MSIEC.kext
                            """
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                        Button("打开配置目录") {
                            NSWorkspace.shared.open(AppPaths.configsDirectory)
                        }
                        Button("打开日志") {
                            NSWorkspace.shared.open(AppPaths.logsDirectory)
                        }
                    }
                }
            }

            Section("关于") {
                LabeledContent("版本", value: "1.0.0")
                LabeledContent("协议", value: "GPL-3.0-or-later")
                Text("YAMDCC for macOS 是 Sparronator9999/YAMDCC 的 macOS 移植版本，寄存器映射与配置文件格式来自上游项目。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear {
            let settings = state.settings.settings
            simulate = settings.forceSimulation
            pollInterval = settings.pollInterval
            applyOnLaunch = settings.applyOnLaunch
            showMenuBar = settings.showMenuBarExtra
        }
    }
}

/// Paths relative to the source checkout, used by the installer shortcuts.
enum RepositoryPaths {
    static var kextPath: String {
        // When running from a built .app, fall back to the canonical location.
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Kext/MSIEC/MSIEC.kext"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Kext/MSIEC/MSIEC.kext"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.path
            ?? candidates[0].path
    }
}
