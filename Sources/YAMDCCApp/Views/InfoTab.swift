// InfoTab.swift
// Mirrors the Windows YAMDCC "Info" tab: current config, device and backend.

import SwiftUI
import AppKit
import YAMDCCKit

struct InfoTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                row("配置:", state.config?.displayName ?? "—")
                row("文件:", state.config?.sourceURL?.path ?? "—")
                row("厂商:", layout?.manufacturer ?? "—")
                row("型号:", layout?.model ?? "—")
                row("作者:", layout?.author ?? "—")
                row("固件:", firmwareText)
                row("后端:", backendText)
                row("EC 固件:", state.backendInfo.firmwareVersion.isEmpty
                    ? "—" : state.backendInfo.firmwareVersion)
                row("状态:", state.statusText)
            }

            Divider()

            HStack(spacing: 8) {
                Button("打开配置…") { state.presentOpenConfig() }
                Button("导入配置…") { state.presentImportConfig() }
                Button("另存为…") { state.saveConfigAs() }
                Button("显示配置文件夹") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configsDirectory])
                }
                Spacer()
                Button("重新连接 EC") { state.connect() }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var layout: DeviceLayout? { state.config?.layout }

    private var firmwareText: String {
        guard let layout else { return "—" }
        var text = layout.firmVer.isEmpty ? "—" : layout.firmVer
        if let date = layout.firmDate, !date.isEmpty {
            text += "  (\(date))"
        }
        return text
    }

    private var backendText: String {
        let info = state.backendInfo
        if info.isSimulated { return "\(info.backend)（模拟）" }
        return info.backend
    }
}
