// MainWindowController.swift
// Guarantees the main window can always be shown, even when SwiftUI never
// instantiated its WindowGroup scene (for example when the app is launched
// as a login item at boot).

import AppKit
import SwiftUI
import YAMDCCKit

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    /// SwiftUI saves its WindowGroup frame under this defaults key. The fallback
    /// window reads and writes the same record so both open paths restore the
    /// same position and size.
    private static let mainWindowFrameKey = "NSWindow Frame main-AppWindow-1"
    private static let legacyFallbackFrameKey = "NSWindow Frame YAMDCCMainFallback"

    /// The window SwiftUI created for the `main` WindowGroup. Registered by
    /// ContentView as soon as it appears; weak because SwiftUI owns it.
    private weak var registeredWindow: NSWindow?
    /// AppKit-owned window used only when SwiftUI has no window to show.
    private var fallbackWindow: NSWindow?
    /// Set while the fallback is being closed because SwiftUI took over; its
    /// (stale) frame must not overwrite the position of the real window.
    private var suppressFallbackFrameSave = false
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
        suppressFallbackFrameSave = true
        fallback.close()
        suppressFallbackFrameSave = false
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
        window.delegate = self
        applySharedFrame(to: window)
        // Older versions stored a separate frame for the fallback window.
        UserDefaults.standard.removeObject(forKey: Self.legacyFallbackFrameKey)
        return window
    }

    // MARK: - Shared window frame

    private func applySharedFrame(to window: NSWindow) {
        guard let saved = UserDefaults.standard.string(forKey: Self.mainWindowFrameKey),
              let frame = Self.parseAutosavedFrame(saved),
              frame.width > 0, frame.height > 0 else {
            window.center()
            return
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main {
            window.setFrame(window.constrainFrameRect(frame, to: screen), display: false)
        } else {
            window.setFrame(frame, display: false)
        }
    }

    /// `NSWindow` frame autosave stores "x y w h screenX screenY screenW screenH".
    private static func parseAutosavedFrame(_ string: String) -> NSRect? {
        let numbers = string.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
        guard numbers.count >= 4 else { return nil }
        return NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    private func saveFallbackFrame(_ window: NSWindow?) {
        guard let window, window === fallbackWindow, !suppressFallbackFrameSave else { return }
        let frame = window.frame
        let screen = window.screen?.frame ?? NSScreen.main?.frame ?? .zero
        let values = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                      screen.origin.x, screen.origin.y, screen.size.width, screen.size.height]
        let string = values.map { String(Int($0.rounded())) }.joined(separator: " ") + " "
        UserDefaults.standard.set(string, forKey: Self.mainWindowFrameKey)
    }

    func windowDidMove(_ notification: Notification) {
        saveFallbackFrame(notification.object as? NSWindow)
    }

    func windowDidResize(_ notification: Notification) {
        saveFallbackFrame(notification.object as? NSWindow)
    }

    func windowWillClose(_ notification: Notification) {
        saveFallbackFrame(notification.object as? NSWindow)
    }
}
