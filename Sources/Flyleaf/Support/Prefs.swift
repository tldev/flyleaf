import Foundation
import Observation

enum PanelSize: String, CaseIterable, Identifiable {
    case compact, regular
    var id: String { rawValue }
    var label: String { self == .compact ? "Compact" : "Regular" }
}

enum PanelTheme: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum AmazonRegion: String, CaseIterable, Identifiable {
    case com, uk, de, fr, es, it, jp, ca, au, br, india

    var id: String { rawValue }

    var domainSuffix: String {
        switch self {
        case .com: return "com"
        case .uk: return "co.uk"
        case .de: return "de"
        case .fr: return "fr"
        case .es: return "es"
        case .it: return "it"
        case .jp: return "co.jp"
        case .ca: return "ca"
        case .au: return "com.au"
        case .br: return "com.br"
        case .india: return "in"
        }
    }

    var label: String {
        switch self {
        case .com: return "amazon.com (US)"
        case .uk: return "amazon.co.uk"
        case .de: return "amazon.de"
        case .fr: return "amazon.fr"
        case .es: return "amazon.es"
        case .it: return "amazon.it"
        case .jp: return "amazon.co.jp"
        case .ca: return "amazon.ca"
        case .au: return "amazon.com.au"
        case .br: return "amazon.com.br"
        case .india: return "amazon.in"
        }
    }

    var readerBaseURL: URL { URL(string: "https://read.amazon.\(domainSuffix)")! }
}

@MainActor
@Observable
final class Prefs {
    static let shared = Prefs()

    private let d = UserDefaults.standard

    var panelSize: PanelSize { didSet { d.set(panelSize.rawValue, forKey: "panelSize") } }
    var panelTheme: PanelTheme { didSet { d.set(panelTheme.rawValue, forKey: "panelTheme") } }
    var clickThrough: Bool { didSet { d.set(clickThrough, forKey: "clickThrough") } }
    var highContrast: Bool { didSet { d.set(highContrast, forKey: "highContrast") } }
    var ambientEnabled: Bool { didSet { d.set(ambientEnabled, forKey: "ambientEnabled") } }
    var ambientDelayMinutes: Int { didSet { d.set(ambientDelayMinutes, forKey: "ambientDelayMinutes") } }
    var rotationSeconds: Int { didSet { d.set(rotationSeconds, forKey: "rotationSeconds") } }
    var notificationsEnabled: Bool { didSet { d.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin") } }
    var prefetchNext: Bool { didSet { d.set(prefetchNext, forKey: "prefetchNext") } }
    var followMostRecent: Bool { didSet { d.set(followMostRecent, forKey: "followMostRecent") } }
    var pollActiveSeconds: Int { didSet { d.set(pollActiveSeconds, forKey: "pollActiveSeconds") } }
    var pollIdleSeconds: Int { didSet { d.set(pollIdleSeconds, forKey: "pollIdleSeconds") } }
    var region: AmazonRegion { didSet { d.set(region.rawValue, forKey: "region") } }
    var onboardingComplete: Bool { didSet { d.set(onboardingComplete, forKey: "onboardingComplete") } }
    var amazonConnected: Bool { didSet { d.set(amazonConnected, forKey: "amazonConnected") } }
    var paused: Bool { didSet { d.set(paused, forKey: "paused") } }
    var panelVisible: Bool { didSet { d.set(panelVisible, forKey: "panelVisible") } }
    var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    var currentASIN: String? { didSet { d.set(currentASIN, forKey: "currentASIN") } }
    var packModel: String { didSet { d.set(packModel, forKey: "packModel") } }
    var capturedUserAgent: String? { didSet { d.set(capturedUserAgent, forKey: "capturedUserAgent") } }

    private init() {
        panelSize = PanelSize(rawValue: d.string(forKey: "panelSize") ?? "") ?? .regular
        panelTheme = PanelTheme(rawValue: d.string(forKey: "panelTheme") ?? "") ?? .auto
        clickThrough = d.object(forKey: "clickThrough") as? Bool ?? false
        highContrast = d.object(forKey: "highContrast") as? Bool ?? false
        ambientEnabled = d.object(forKey: "ambientEnabled") as? Bool ?? true
        ambientDelayMinutes = d.object(forKey: "ambientDelayMinutes") as? Int ?? 3
        rotationSeconds = d.object(forKey: "rotationSeconds") as? Int ?? 20
        notificationsEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? false
        launchAtLogin = d.object(forKey: "launchAtLogin") as? Bool ?? false
        prefetchNext = d.object(forKey: "prefetchNext") as? Bool ?? true
        followMostRecent = d.object(forKey: "followMostRecent") as? Bool ?? true
        pollActiveSeconds = d.object(forKey: "pollActiveSeconds") as? Int ?? 50
        pollIdleSeconds = d.object(forKey: "pollIdleSeconds") as? Int ?? 600
        region = AmazonRegion(rawValue: d.string(forKey: "region") ?? "") ?? .com
        onboardingComplete = d.object(forKey: "onboardingComplete") as? Bool ?? false
        amazonConnected = d.object(forKey: "amazonConnected") as? Bool ?? false
        paused = d.object(forKey: "paused") as? Bool ?? false
        panelVisible = d.object(forKey: "panelVisible") as? Bool ?? false
        hotkeyEnabled = d.object(forKey: "hotkeyEnabled") as? Bool ?? true
        currentASIN = d.string(forKey: "currentASIN")
        packModel = d.string(forKey: "packModel") ?? "claude-opus-5"
        capturedUserAgent = d.string(forKey: "capturedUserAgent")
    }
}
