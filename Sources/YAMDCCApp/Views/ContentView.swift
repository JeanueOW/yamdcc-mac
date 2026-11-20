// ContentView.swift
// Main window: Fan control / Extras / Info tabs, exactly like the Windows editor.

import SwiftUI
import YAMDCCKit

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    enum Tab: String, CaseIterable, Identifiable {
        case fanControl, extras, info
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fanControl: return "风扇控制"
            case .extras: return "额外设置"
            case .info: return "信息"
            }
        }
    }

    @State private var tab: Tab = .fanControl

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Divider()

            Group {
                switch tab {
                case .fanControl: FanControlTab()
                case .extras: ExtrasTab()
                case .info: InfoTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            statusBar
        }
        .frame(minWidth: 680, minHeight: 600)
        .navigationTitle("YAMDCC 配置编辑器")
        .onAppear { installStatusItem() }
        .alert("出错了", isPresented: Binding(
            get: { state.lastError != nil },
            set: { if !$0 { state.lastError = nil } })) {
            Button("好") { state.lastError = nil }
        } message: {
            Text(state.lastError ?? "")
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(state.statusText)
                .lineLimit(1)
                .truncationMode(.tail)

            if let state = state.monitor?.state {
                Text("风扇转速: \(speedText(state))   RPM: \(rpmText(state))   温度: \(tempText(state))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("还原") { state.revertEdits() }
                .keyboardShortcut("z", modifiers: [.command])
            Button("应用") { state.apply() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .buttonStyle(.borderedProminent)
                .disabled(state.config == nil || state.isApplying)
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func tempText(_ sample: DeviceState) -> String {
        "\(value(sample.temp(.cpu))) / \(value(sample.temp(.gpu))) °C"
    }

    private func rpmText(_ sample: DeviceState) -> String {
        "\(value(sample.rpm(.cpu))) / \(value(sample.rpm(.gpu)))"
    }

    private func speedText(_ sample: DeviceState) -> String {
        "\(value(sample.speed(.cpu)))% / \(value(sample.speed(.gpu)))%"
    }

    private func value(_ number: Int?) -> String {
        guard let number else { return "—" }
        return "\(number)"
    }


    private func installStatusItem() {
        StatusItemController.shared.attach(state: state)
        StatusItemController.shared.openMainWindow = { openWindow(id: "main") }
    }
}
