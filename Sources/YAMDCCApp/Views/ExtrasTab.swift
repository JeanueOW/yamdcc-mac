// ExtrasTab.swift
// Mirrors the Windows YAMDCC "Extras" tab.

import SwiftUI
import YAMDCCKit

struct ExtrasTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 18) {
                chargeRow
                perfModeRow
                keySwapRow
                keyLightRow
                fanModeRow
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    // MARK: Rows

    private var chargeRow: some View {
        GridRow {
            Text("充电上限:")
                .gridColumnAlignment(.trailing)
            HStack(spacing: 8) {
                Toggle("启用", isOn: chargeEnabledBinding)
                    .toggleStyle(.checkbox)
                SpinBox(value: chargePercentBinding, range: 50...100, width: 46)
                Text("%")
                    .foregroundStyle(.secondary)
            }
            .disabled(state.config?.layout.chargeLimit == nil)
        }
    }

    private var perfModeRow: some View {
        GridRow {
            Text("默认性能模式:")
                .gridColumnAlignment(.trailing)
            Picker("", selection: perfModeBinding) {
                ForEach(perfOptions.indices, id: \.self) { index in
                    Text(perfOptions[index].name).tag(index)
                }
            }
            .labelsHidden()
            .frame(width: 210)
            .disabled(perfOptions.isEmpty)
        }
    }

    private var keySwapRow: some View {
        GridRow {
            Text("交换 Win 和 Fn 键:")
                .gridColumnAlignment(.trailing)
            Toggle("启用", isOn: keySwapBinding)
                .toggleStyle(.checkbox)
                .disabled(state.config?.layout.keySwap == nil)
        }
    }

    private var keyLightRow: some View {
        GridRow {
            Text("键盘背光:")
                .gridColumnAlignment(.trailing)
            HStack(spacing: 8) {
                Text("关")
                Slider(value: keyLightBinding, in: 0...100, step: 1)
                    .frame(width: 240)
                Text("最亮")
                Text("\(state.config?.settings.keyLight ?? 0)%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
            }
            .disabled(state.config?.layout.keyLight == nil)
        }
    }

    private var fanModeRow: some View {
        GridRow {
            Text("风扇模式:")
                .gridColumnAlignment(.trailing)
            Picker("", selection: fanModeBinding) {
                ForEach(fanModeOptions.indices, id: \.self) { index in
                    Text(fanModeOptions[index].displayName).tag(index)
                }
            }
            .labelsHidden()
            .frame(width: 210)
            .disabled(fanModeOptions.isEmpty)
        }
    }

    // MARK: Bindings

    private var perfOptions: [EnumOption] { state.config?.layout.perfMode?.options ?? [] }
    private var fanModeOptions: [EnumOption] { state.config?.layout.fanMode?.options ?? [] }

    private var chargeEnabledBinding: Binding<Bool> {
        Binding(get: { (state.config?.settings.chargeLimit ?? 0) > 0 },
                set: { enabled in
                    state.setPendingChargeLimit(enabled ? 80 : 0)
                })
    }

    private var chargePercentBinding: Binding<Int> {
        Binding(get: { max(50, state.config?.settings.chargeLimit ?? 80) },
                set: { state.setPendingChargeLimit($0) })
    }

    private var perfModeBinding: Binding<Int> {
        Binding(get: { state.defaultPerfModeIndex },
                set: { state.setDefaultPerfMode($0) })
    }

    private var fanModeBinding: Binding<Int> {
        Binding(get: {
            let selected = state.config?.settings.fanMode ?? -1
            if selected >= 0 { return selected }
            return state.config?.layout.fanMode?.defaultIndex ?? 0
        }, set: { state.setPendingFanMode($0) })
    }

    private var keySwapBinding: Binding<Bool> {
        Binding(get: { state.config?.settings.keySwap ?? false },
                set: { state.setPendingKeySwap($0) })
    }

    private var keyLightBinding: Binding<Double> {
        Binding(get: { Double(state.config?.settings.keyLight ?? 0) },
                set: { state.setPendingKeyLight(Int($0.rounded())) })
    }
}
