import AppKit

/// Keeps the app in the Dock / Cmd-Tab only while a real window is on screen.
/// With no windows it becomes a menu-bar-only (accessory) app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        for name in [NSWindow.willCloseNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshPolicy),
                                                   name: name, object: nil)
        }
        refreshPolicy()
    }

    @objc private func refreshPolicy() {
        DispatchQueue.main.async { AppDelegate.applyPolicy() }
    }

    static func applyPolicy() {
        let hasWindow = NSApp.windows.contains { window in
            (window.isVisible || window.isMiniaturized) && window.canBecomeMain && !(window is NSPanel)
        }
        let target: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        if NSApp.activationPolicy() != target {
            NSApp.setActivationPolicy(target)
        }
    }
}
