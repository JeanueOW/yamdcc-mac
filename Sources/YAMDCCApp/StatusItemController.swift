import AppKit
import Combine
import SwiftUI
import YAMDCCKit

/// Owns the menu bar status item: a two-line CPU/GPU readout plus a native menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private weak var state: AppState?
    private var cancellables: Set<AnyCancellable> = []


    /// Set by ContentView so the menu can reopen the SwiftUI window after it was closed.
    var openMainWindow: (() -> Void)?

    func attach(state: AppState) {
        guard statusItem == nil else { return }
        self.state = state

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if let button = item.button {
            button.cell?.usesSingleLineMode = false
            button.cell?.wraps = true
            button.toolTip = "YAMDCC"
        }
        statusItem = item
        self.menu = menu

        state.monitor?.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshTitle() }
            }
            .store(in: &cancellables)

        refreshTitle()
    }

    private func refreshTitle() {
        guard let button = statusItem?.button, let state else { return }
        let device = state.monitor?.state

        func value(_ index: Int) -> String {
            let temp = device?.temps.indices.contains(index) == true ? "\(device!.temps[index])°" : "—"
            let rpm = device?.rpms.indices.contains(index) == true ? "\(device!.rpms[index])RPM" : "—RPM"
            return "\(index == 0 ? "CPU" : "GPU") \(temp) \(rpm)"
        }

        let lines = [value(0), value(1)]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let widths = lines.map { ($0 as NSString).size(withAttributes: attributes).width }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height: CGFloat = 22
        let width = ceil(widths.max() ?? 0) + 2

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let total = lineHeight * CGFloat(lines.count)
            let top = (height - total) / 2
            for (index, line) in lines.enumerated() {
                let baseline = height - top - lineHeight * CGFloat(index + 1) - font.descender
                (line as NSString).draw(at: NSPoint(x: 1, y: baseline), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true

        button.image = image
        button.imagePosition = .imageOnly
        button.title = ""
        button.setAccessibilityLabel(lines.joined(separator: "，"))
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let state else { return }
        menu.removeAllItems()

        let device = state.monitor?.state
        if let layout = state.config?.layout {
            for (index, fan) in layout.fans.enumerated() {
                let temp = device?.temps.indices.contains(index) == true ? "\(device!.temps[index])°" : "—"
                let speed = device?.speeds.indices.contains(index) == true ? "\(device!.speeds[index])%" : "—%"
                let rpm = device?.rpms.indices.contains(index) == true ? "\(device!.rpms[index]) RPM" : "— RPM"
                let short = fan.name.replacingOccurrences(of: " Fan", with: "")
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(
                    string: "\(short)：\(temp) · \(speed) · \(rpm)",
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize,
                                                                        weight: .regular),
                                 .foregroundColor: NSColor.disabledControlTextColor])
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        let blast = NSMenuItem(title: "全速模式", action: #selector(toggleFullBlast), keyEquivalent: "")
        blast.target = self
        blast.state = (device?.fullBlast ?? false) ? .on : .off
        menu.addItem(blast)

        if let fanMode = state.config?.layout.fanMode {
            let currentIndex = state.fanModeIndex
            let currentName = fanMode.options.indices.contains(currentIndex)
                ? fanMode.options[currentIndex].displayName : "—"
            let parent = NSMenuItem(title: "风扇模式：\(currentName)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (index, option) in fanMode.options.enumerated() {
                let item = NSMenuItem(title: option.displayName,
                                      action: #selector(selectFanMode(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = index
                item.state = index == currentIndex ? .on : .off
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }

        if let set = state.profileSet(for: state.selectedTarget) {
            let current = set.profiles.indices.contains(set.selected) ? set.profiles[set.selected].name : "—"
            let parent = NSMenuItem(title: "配置档案：\(current)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (index, profile) in set.profiles.enumerated() {
                let item = NSMenuItem(title: profile.name,
                                      action: #selector(selectProfile(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = index
                item.state = index == set.selected ? .on : .off
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }

        menu.addItem(.separator())

        let open = NSMenuItem(title: "打开主窗口", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 YAMDCC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
    }

    @objc private func toggleFullBlast() {
        guard let state else { return }
        let current = state.monitor?.state?.fullBlast ?? false
        state.setFullBlast(!current)
    }

    @objc private func selectFanMode(_ sender: NSMenuItem) {
        state?.setFanMode(index: sender.tag)
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let state else { return }
        state.selectProfile(sender.tag, for: state.selectedTarget)
        state.apply()
    }

    @objc private func openWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}
