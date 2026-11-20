// FanControlTab.swift
// Mirrors the Windows YAMDCC "Fan control" tab: fan/profile/perf-mode row,
// seven-point curve with vertical bars, Up/Down temperature rows.

import SwiftUI
import YAMDCCKit

struct FanControlTab: View {
    @EnvironmentObject private var state: AppState

    private enum Field { case speed, up, down }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            advancedRow
            curveGrid
                .disabled(!state.isAdvancedFanMode)
                .opacity(state.isAdvancedFanMode ? 1 : 0.45)
            Spacer(minLength: 0)
            Toggle("全速运行（Full Blast）", isOn: Binding(
                get: { state.config?.settings.fullBlast ?? false },
                set: { state.setPendingFullBlast($0) }))
                .toggleStyle(.checkbox)
        }
        .padding(16)
    }

    // MARK: Advanced fan mode

    private var advancedRow: some View {
        HStack(spacing: 10) {
            Toggle("启用高级风扇模式（使用自定义曲线）", isOn: Binding(
                get: { state.isAdvancedFanMode },
                set: { state.setAdvancedFanMode($0) }))
                .toggleStyle(.checkbox)
            Text(state.isAdvancedFanMode
                 ? "EC 当前按自定义曲线运行"
                 : "EC 按「额外设置 → 风扇模式」运行：\(currentFanModeName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var currentFanModeName: String {
        let options = state.fanModeOptions
        let index = state.fanModeIndex
        return options.indices.contains(index) ? options[index].displayName : "—"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("风扇:").fixedSize()
            Picker("", selection: fanBinding) {
                ForEach(fanNames.indices, id: \.self) { index in
                    Text(fanNames[index]).tag(index)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            Text("配置档案:").fixedSize()
            Picker("", selection: profileBinding) {
                ForEach(profileNames.indices, id: \.self) { index in
                    Text(profileNames[index]).tag(index)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Button { state.addProfile(for: target) } label: {
                Image(systemName: "plus")
            }
            .frame(width: 24)
            .help("新建配置档案")

            Button { state.deleteProfile(for: target) } label: {
                Image(systemName: "minus")
            }
            .frame(width: 24)
            .disabled(profileNames.count <= 1)
            .help("删除配置档案")

            Button { state.renameProfileInteractively(for: target) } label: {
                Image(systemName: "pencil")
            }
            .frame(width: 24)
            .help("重命名配置档案")

            Spacer(minLength: 12)

            Text("性能模式:").fixedSize()
            Picker("", selection: perfModeBinding) {
                Text(followDefaultTitle).tag(-1)
                ForEach(perfOptions.indices, id: \.self) { index in
                    Text(perfOptions[index].name).tag(index)
                }
            }
            .labelsHidden()
            .frame(width: 215)
            .disabled(perfOptions.isEmpty)
        }
    }

    // MARK: Curve

    @ViewBuilder
    private var curveGrid: some View {
        if let profile = state.profile(for: target) {
            let pointCount = profile.thresholds.count
            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(width: 86, height: 1)
                    ForEach(0..<pointCount, id: \.self) { index in
                        SpinBox(value: thresholdBinding(index, .speed),
                                range: fanMinSpeed...max(fanMinSpeed + 1, fanMaxSpeed),
                                width: 34)
                            .frame(minWidth: 54, maxWidth: .infinity)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 86, height: 1)
                    ForEach(0..<pointCount, id: \.self) { index in
                        CurveColumn(
                            speed: profile.thresholds[index].speed,
                            maxSpeed: fanMaxSpeed,
                            onDrag: { newSpeed in
                                state.setThreshold(target: target, index: index, speed: newSpeed)
                            })
                            .frame(minWidth: 54, maxWidth: .infinity, minHeight: 240)
                    }
                }
                GridRow {
                    Text("上升阈值(°C)")
                        .frame(width: 86, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    ForEach(0..<pointCount, id: \.self) { index in
                        if index == 0 {
                            Color.clear.frame(height: 1)
                        } else {
                            SpinBox(value: thresholdBinding(index, .up), range: 20...110, width: 34)
                                .frame(minWidth: 54, maxWidth: .infinity)
                        }
                    }
                }
                GridRow {
                    Text("下降阈值(°C)")
                        .frame(width: 86, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    ForEach(0..<pointCount, id: \.self) { index in
                        if index == 0 {
                            Color.clear.frame(height: 1)
                        } else {
                            SpinBox(value: thresholdBinding(index, .down), range: 20...110, width: 34)
                                .frame(minWidth: 54, maxWidth: .infinity)
                        }
                    }
                }
            }
        } else {
            Text("尚未载入配置")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Bindings

    private var target: FanTarget { state.selectedTarget }

    private var fanNames: [String] {
        state.config?.layout.fans.map(\.name) ?? ["CPU Fan", "GPU Fan"]
    }

    private var fanMinSpeed: Int {
        state.config?.layout.fans[safe: target.rawValue]?.minSpeed ?? 0
    }

    private var fanMaxSpeed: Int {
        state.config?.layout.fans[safe: target.rawValue]?.maxSpeed ?? 100
    }

    private var fanBinding: Binding<Int> {
        Binding(get: { target.rawValue },
                set: { state.selectedTarget = FanTarget(rawValue: $0) ?? .cpu })
    }

    private var profileNames: [String] {
        state.profileSet(for: target)?.profiles.map(\.name) ?? []
    }

    private var profileBinding: Binding<Int> {
        Binding(get: { state.profileSet(for: target)?.selected ?? 0 },
                set: { state.selectProfile($0, for: target) })
    }

    private var perfOptions: [EnumOption] {
        state.config?.layout.perfMode?.options ?? []
    }

    /// "默认性能模式（Balanced）" with the current default filled in.
    private var followDefaultTitle: String {
        let index = state.defaultPerfModeIndex
        if perfOptions.indices.contains(index) {
            return "默认性能模式（\(perfOptions[index].name)）"
        }
        return "默认性能模式"
    }

    private var perfModeBinding: Binding<Int> {
        Binding(get: { state.profilePerfModeIndex },
                set: { state.setProfilePerfModeUnified($0) })
    }

    private func thresholdBinding(_ index: Int, _ field: Field) -> Binding<Int> {
        func current() -> Int {
            guard let threshold = state.profile(for: target)?.thresholds[safe: index] else { return 0 }
            switch field {
            case .speed: return threshold.speed
            case .up: return threshold.up
            case .down: return threshold.down
            }
        }
        return Binding(get: { current() }, set: { newValue in
            switch field {
            case .speed: state.setThreshold(target: target, index: index, speed: newValue)
            case .up: state.setThreshold(target: target, index: index, up: newValue)
            case .down: state.setThreshold(target: target, index: index, down: newValue)
            }
        })
    }
}

/// One dotted guide with a draggable blue marker at the point's speed height.
private struct CurveColumn: View {
    let speed: Int
    let maxSpeed: Int
    let onDrag: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let markerHeight: CGFloat = 12
            let ceiling = max(maxSpeed, 1)
            let fraction = CGFloat(min(max(speed, 0), ceiling)) / CGFloat(ceiling)
            let markerY = (1 - fraction) * (height - markerHeight)

            ZStack(alignment: .top) {
                Path { path in
                    path.move(to: CGPoint(x: geometry.size.width / 2, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width / 2, y: height))
                }
                .stroke(Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 4]))

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 30, height: markerHeight)
                    .offset(y: markerY)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let y = min(max(value.location.y, 0), height)
                                let newSpeed = Int(((1 - y / height) * CGFloat(ceiling)).rounded())
                                onDrag(min(max(newSpeed, 0), ceiling))
                            }
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
    }
}
