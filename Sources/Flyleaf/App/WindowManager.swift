import AppKit
import SwiftUI

// All regular windows (onboarding, settings, shelf, ask, recap, pickers)
// are managed here; the app itself stays a menu bar accessory.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    var state: AppState?
    private var windows = [String: NSWindow]()

    private func present(
        id: String,
        title: String,
        size: NSSize,
        resizable: Bool = false,
        @ViewBuilder content: () -> some View
    ) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { mask.insert(.resizable) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        if id == "main" {
            window.titleVisibility = .hidden          // the warm bar carries the title
            window.isRestorable = false               // always open at the top
            window.backgroundColor = NSColor(red: 0.957, green: 0.945, blue: 0.918, alpha: 1)
        }
        window.contentViewController = NSHostingController(rootView: AnyView(content()))
        // Assigning contentViewController shrinks the window to the hosting
        // view's fitting size, which for flexible SwiftUI content is tiny.
        window.setContentSize(size)
        window.minSize = NSSize(width: size.width * 0.6, height: size.height * 0.6)
        window.center()
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = window.identifier?.rawValue else { return }
        windows.removeValue(forKey: id)
    }

    func close(id: String) {
        windows[id]?.close()
    }

    // MARK: Specific windows

    func showOnboarding() {
        guard let state else { return }
        present(id: "onboarding", title: "Welcome to Flyleaf", size: NSSize(width: 760, height: 600)) {
            OnboardingView().environment(state)
        }
    }

    func showLogin() {
        guard let state else { return }
        present(id: "login", title: "Connect Amazon", size: NSSize(width: 880, height: 680), resizable: true) {
            StandaloneLoginView().environment(state)
        }
    }

    func showSettings() {
        guard let state else { return }
        present(id: "settings", title: "Flyleaf Settings", size: NSSize(width: 600, height: 520)) {
            SettingsView().environment(state)
        }
    }

    func showMain(tab: MainTab? = nil) {
        guard let state else { return }
        if let tab { state.mainTab = tab }
        present(id: "main", title: "Flyleaf", size: NSSize(width: 1240, height: 880), resizable: true) {
            MainWindowView().environment(state)
        }
    }

    func showAsk() {
        guard let state else { return }
        present(id: "ask", title: "Ask", size: NSSize(width: 520, height: 380)) {
            AskView().environment(state)
        }
    }

    func showRecap() {
        guard let state else { return }
        present(id: "recap", title: "Previously On", size: NSSize(width: 520, height: 440)) {
            RecapView().environment(state)
        }
    }

    func showManualPicker() {
        guard let state else { return }
        present(id: "manual", title: "Choose a Book", size: NSSize(width: 520, height: 500)) {
            ManualBookView().environment(state)
        }
    }
}
