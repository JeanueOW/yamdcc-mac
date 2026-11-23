// MainWindowController.swift
// Guarantees the main window can always be shown, even when SwiftUI never
// instantiated its WindowGroup scene (for example when the app is launched
// as a login item at boot).

import AppKit
import SwiftUI
import YAMDCCKit

@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    /// The window SwiftUI created for the `main` WindowGroup. Registered by
    /// ContentView as soon as it appears; weak because SwiftUI owns it.
    private weak var registeredWindow: NSWindow?
    /// AppKit-owned window used only when SwiftUI has no window to show.
    private var fallbackWindow: NSWindow?
    /// Strong reference to the shared app state (the app owns it for its lifetime).
    private var state: AppState?

    func configure(state: AppState) {
        self.state = state
    }

    /// Called from ContentView once it is hosted in a window.
    func register(window: NSWindow?) {
        guard let window, window.canBecomeMain, !(window is NSPanel) else { return }
        // ContentView also runs inside the fallback window; the fallback is
        // tracked separately, so never let its updates replace the SwiftUI window.
        guard window !== fallbackWindow else { return }
        registeredWindow = window
        // Once SwiftUI has a real window, retire the stand-in so the user never
        // ends up with two main windows side by side.
        if window.isVisible {
            dismissFallback(unless: window)
        }
        // A window may appear after the launch-time policy check (e.g. at login).
        DispatchQueue.main.async { AppDelegate.applyPolicy() }
    }

    private func dismissFallback(unless window: NSWindow) {
        guard let fallback = fallbackWindow, fallback !== window,
              fallback.isVisible || fallback.isMiniaturized else { return }
        fallback.close()
        Log.shared.debug("关闭备用窗口：SwiftUI 主窗口已出现")
    }

    /// Bring the main window to the front, creating one if necessary.
    @discardableResult
    func show() -> Bool {
        guard let state else { return false }

        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        if let window = registeredWindow ?? existingSwiftUIWindow() {
            registeredWindow = window
            dismissFallback(unless: window)
            window.makeKeyAndOrderFront(nil)
            Log.shared.debug("打开主窗口：复用 SwiftUI 窗口")
            return true
        }

        if let window = fallbackWindow {
            window.makeKeyAndOrderFront(nil)
            Log.shared.debug("打开主窗口：复用备用窗口")
            return true
        }

        let window = makeFallbackWindow(state: state)
        fallbackWindow = window
        window.makeKeyAndOrderFront(nil)
        Log.shared.info("SwiftUI 主窗口不存在，已创建备用窗口")
        return true
    }

    /// Fallback lookup for a SwiftUI window that exists but was never registered
    /// (e.g. it was created before ContentView appeared).
    private func existingSwiftUIWindow() -> NSWindow? {
        NSApp.windows.first { window in
            guard window.canBecomeMain, !(window is NSPanel) else { return false }
            if let identifier = window.identifier?.rawValue {
                return identifier.hasPrefix("main")
            }
            return window.title == "YAMDCC 配置编辑器"
        }
    }

    private func makeFallbackWindow(state: AppState) -> NSWindow {
        let hosting = NSHostingController(rootView: ContentView().environmentObject(state))
        let window = NSWindow(contentViewController: hosting)
        window.title = "YAMDCC 配置编辑器"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 780))
        window.setFrameAutosaveName("YAMDCCMainFallback")
        window.center()
        return window
    }
}
