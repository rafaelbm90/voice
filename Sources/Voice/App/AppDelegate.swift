import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func prepareForStandardWindowPresentation() {
        setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setActivationPolicy(.accessory)
        registerWindowObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func registerWindowObservers() {
        let notificationCenter = NotificationCenter.default

        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowLifecycleNotification(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowLifecycleNotification(_:)),
            name: NSWindow.didMiniaturizeNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowLifecycleNotification(_:)),
            name: NSWindow.didDeminiaturizeNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowLifecycleNotification(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc
    private func handleWindowLifecycleNotification(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isStandardAppWindow(window) else { return }
        let excludedWindow = notification.name == NSWindow.willCloseNotification ? window : nil
        syncActivationPolicyToWindowState(excluding: excludedWindow)
    }

    private func syncActivationPolicyToWindowState(excluding excludedWindow: NSWindow? = nil) {
        let hasVisibleStandardWindow = NSApp.windows.contains { window in
            guard isStandardAppWindow(window) else { return false }
            guard window != excludedWindow else { return false }
            return window.isVisible && !window.isMiniaturized
        }

        setActivationPolicy(hasVisibleStandardWindow ? .regular : .accessory)
    }

    private func isStandardAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }

    private func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}
