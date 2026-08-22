import SwiftUI
import UserNotifications

@main
struct FlyleafApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environment(delegate.state)
        } label: {
            MenuBarLabel(state: delegate.state)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let state: AppState

    var body: some View {
        if let percent = state.position?.percent, state.currentBook != nil {
            Image(systemName: "book.fill")
            Text("\(Int(percent))%")
        } else if state.connection == .needsReauth {
            Image(systemName: "book.closed")
            Text("!")
        } else {
            Image(systemName: "book.closed")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state: AppState

    override init() {
        state = AppState()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log(.app, "Flyleaf launching (\(Bundle.main.bundleIdentifier ?? "no bundle"))")
        NSApp.setActivationPolicy(.accessory)

        URLCache.shared = URLCache(
            memoryCapacity: 40 * 1024 * 1024,
            diskCapacity: 300 * 1024 * 1024
        )

        WindowManager.shared.state = state
        PanelController.shared.configure(state: state)
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared

        HotKeyManager.shared.onAsk = { WindowManager.shared.showAsk() }
        if Prefs.shared.hotkeyEnabled {
            HotKeyManager.shared.enable()
        }

        let demo = CommandLine.arguments.contains("--demo")
        state.bootstrap(demo: demo)

        if Prefs.shared.onboardingComplete || demo {
            WindowManager.shared.showMain()
            if Prefs.shared.panelVisible {
                PanelController.shared.show()
            }
            state.poller.start()
        } else {
            WindowManager.shared.showOnboarding()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            URLCommands.handle(url, state: state)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log(.app, "Flyleaf terminating")
    }
}

// flyleaf:// scheme, handy for scripting and Shortcuts:
//   flyleaf://demo, flyleaf://sync, flyleaf://panel/toggle, flyleaf://ask,
//   flyleaf://shelf, flyleaf://settings, flyleaf://chapter?set=4,
//   flyleaf://session/start
@MainActor
enum URLCommands {
    static func handle(_ url: URL, state: AppState) {
        log(.app, "URL command: \(url.absoluteString)")
        switch url.host {
        case "demo":
            state.loadDemo()
            WindowManager.shared.showMain()
        case "sync":
            state.poller.pollSoon()
        case "panel":
            if url.path.contains("show") {
                PanelController.shared.show()
            } else if url.path.contains("hide") {
                PanelController.shared.hide()
            } else {
                PanelController.shared.toggle()
            }
        case "ask":
            WindowManager.shared.showAsk()
        case "dashboard", "main", "open":
            WindowManager.shared.showMain(tab: .dashboard)
        case "shelf", "cast":
            WindowManager.shared.showMain(tab: .cast)
        case "atlas":
            WindowManager.shared.showMain(tab: .atlas)
        case "stats":
            WindowManager.shared.showMain(tab: .stats)
        case "settings":
            WindowManager.shared.showSettings()
        case "recap":
            WindowManager.shared.showRecap()
        case "chapter":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let value = comps?.queryItems?.first(where: { $0.name == "set" })?.value,
               let chapter = Int(value) {
                state.setManualChapter(chapter)
            }
        case "diag":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let term = comps?.queryItems?.first(where: { $0.name == "q" })?.value ?? "apple"
            if let kindle = state.kindle {
                Task { await kindle.runLibraryDiagnostics(searchTerm: term) }
            } else {
                log(.kindle, .warn, "DIAG requested but Amazon is not connected")
            }
        case "register":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let term = comps?.queryItems?.first(where: { $0.name == "q" })?.value ?? "apple"
            Task { await state.probeDeviceRegistration(term: term) }
        case "docsync":
            Task { await state.enablePersonalDocSync() }
        case "import":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let path = comps?.queryItems?.first(where: { $0.name == "path" })?.value {
                state.importEPUB(url: URL(fileURLWithPath: path))
                WindowManager.shared.showMain()
            }
        case "session":
            // "Start reading session" for Shortcuts and Focus automations.
            Prefs.shared.paused = false
            state.poller.pollSoon()
        default:
            log(.app, .warn, "Unknown URL command: \(url.absoluteString)")
        }
    }
}
