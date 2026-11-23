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

        // SwiftUI creates its WindowGroup window shortly *after* this callback.
        // Applying the accessory policy right away races with that, and when the
        // app is started as a login item the window may be created much later
        // (or not at all), which used to leave the app windowless and unable to
        // reopen its UI. Only downgrade after SwiftUI had a chance to show it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            AppDelegate.applyPolicy()
        }
    }

    @objc private func refreshPolicy() {
        DispatchQueue.main.async { AppDelegate.applyPolicy() }
    }

    /// Dock icon / reopen: always bring the main window back if none is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindowController.shared.show()
        }
        return true
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
