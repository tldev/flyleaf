import Foundation
import CryptoKit
import WebKit

struct KindleDeviceCredentials: Codable {
    var adpToken: String
    var devicePrivateKey: String
    var accessToken: String
    var refreshToken: String
    var deviceSerial: String
    var deviceType: String
    var registeredAt: Date

    func signer() -> ADPSigner? {
        ADPSigner(adpToken: adpToken, privateKeyPEMorDER: devicePrivateKey)
    }
}

enum DeviceAuthError: Error, CustomStringConvertible {
    case oauthFailed(String)
    case registerFailed(String)
    case noCode

    var description: String {
        switch self {
        case .oauthFailed(let m): return "Device sign-in failed: \(m)"
        case .registerFailed(let m): return "Device registration failed: \(m)"
        case .noCode: return "Amazon did not return an authorization code"
        }
    }
}

// Registers this Mac as an Amazon "device" so Flyleaf can read Whispersync
// data (personal-document reading positions) the way the Kindle apps do. The
// OAuth step reuses the already-signed-in session in a hidden web view, so
// there is no second login and no password ever seen.
@MainActor
final class KindleDeviceAuth {
    static let account = "kindle-device-credentials"

    private let region: AmazonRegion
    private var webView: WKWebView?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var navDelegate: OAuthNavDelegate?

    init(region: AmazonRegion) {
        self.region = region
    }

    static func stored() -> KindleDeviceCredentials? {
        guard let json = Keychain.get(account: account), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(KindleDeviceCredentials.self, from: data)
    }

    static func store(_ creds: KindleDeviceCredentials) {
        guard let data = try? JSONEncoder().encode(creds), let json = String(data: data, encoding: .utf8) else { return }
        Keychain.set(json, account: account)
    }

    static func clear() {
        Keychain.delete(account: account)
    }

    var isRegistered: Bool { Self.stored() != nil }

    // MARK: Registration

    private var marketplaceId: String {
        switch region {
        case .com: return "ATVPDKIKX0DER"
        case .uk: return "A1F83G8C2ARO7P"
        case .de: return "A1PA6795UKMFR9"
        case .fr: return "A13V1IB3VIYZZH"
        case .es: return "A1RKKUPIHCS9HS"
        case .it: return "APJ6JRA9NG5V4"
        case .jp: return "A1VC38T7YXB528"
        case .ca: return "A2EUQ1WTGCTBG2"
        case .au: return "A39IBJ37TRP1C6"
        case .br: return "A2Q3Y263D00KWC"
        case .india: return "A21TJRUUN4KGV"
        }
    }

    private var countryCode: String {
        switch region {
        case .com: return "us"
        case .uk: return "uk"
        case .india: return "in"
        default: return region.rawValue
        }
    }

    static let deviceTypeConstant = "A2CZJZGLK2JJVM"
    private static let deviceType = deviceTypeConstant

    func register() async throws -> KindleDeviceCredentials {
        let serial = Self.randomSerial()
        let verifier = Self.codeVerifier()
        let challenge = Self.codeChallenge(verifier)
        let clientId = Self.clientId(serial: serial)

        let authURL = buildOAuthURL(serial: serial, challenge: challenge, clientId: clientId)
        log(.auth, "Starting device OAuth (serial \(serial.prefix(8))…)")
        let code = try await captureAuthorizationCode(authURL: authURL)
        log(.auth, "Captured device authorization code")

        let creds = try await callRegister(code: code, verifier: verifier, clientId: clientId, serial: serial)
        Self.store(creds)
        log(.auth, "Device registered; adp token acquired")
        return creds
    }

    private func buildOAuthURL(serial: String, challenge: String, clientId: String) -> URL {
        let base = region.wwwBaseURL
        let params: [(String, String)] = [
            ("openid.oa2.response_type", "code"),
            ("openid.oa2.code_challenge_method", "S256"),
            ("openid.oa2.code_challenge", challenge),
            ("openid.return_to", "\(base.absoluteString)/ap/maplanding"),
            ("openid.assoc_handle", "amzn_audible_ios_\(countryCode)"),
            ("openid.identity", "http://specs.openid.net/auth/2.0/identifier_select"),
            ("pageId", "amzn_audible_ios"),
            ("accountStatusPolicy", "P1"),
            ("openid.claimed_id", "http://specs.openid.net/auth/2.0/identifier_select"),
            ("openid.mode", "checkid_setup"),
            ("openid.ns.oa2", "http://www.amazon.com/ap/ext/oauth/2"),
            ("openid.oa2.client_id", "device:\(clientId)"),
            ("openid.ns.pape", "http://specs.openid.net/extensions/pape/1.0"),
            ("marketPlaceId", marketplaceId),
            ("openid.oa2.scope", "device_auth_access"),
            ("forceMobileLayout", "true"),
            ("openid.ns", "http://specs.openid.net/auth/2.0"),
            ("openid.pape.max_auth_age", "0"),
        ]
        var comps = URLComponents(url: base.appendingPathComponent("ap/signin"), resolvingAgainstBaseURL: false)!
        comps.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        return comps.url!
    }

    // Loads the authorize URL in a hidden web view. Because the session is
    // already signed in, Amazon redirects straight to /ap/maplanding with the
    // authorization code in the query. If it instead lands on a login or
    // consent page, the web view is surfaced so the user can approve.
    private func captureAuthorizationCode(authURL: URL) async throws -> String {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 700), configuration: config)
        webView = wv
        let delegate = OAuthNavDelegate { [weak self] result in
            self?.finishOAuth(result)
        }
        navDelegate = delegate
        wv.navigationDelegate = delegate
        wv.load(URLRequest(url: authURL))

        // If no code within a few seconds, show the window for manual approval.
        let surfaceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await self?.surfaceIfNeeded()
        }

        return try await withCheckedThrowingContinuation { continuation in
            codeContinuation = continuation
            _ = surfaceTask
        }
    }

    private func finishOAuth(_ result: Result<String, Error>) {
        guard let continuation = codeContinuation else { return }
        codeContinuation = nil
        DeviceAuthWindow.shared.close()
        webView?.navigationDelegate = nil
        webView = nil
        navDelegate = nil
        continuation.resume(with: result)
    }

    private func surfaceIfNeeded() {
        guard codeContinuation != nil, let wv = webView else { return }
        log(.auth, "Device OAuth needs interaction; showing sign-in window")
        DeviceAuthWindow.shared.show(webView: wv)
    }

    private func callRegister(code: String, verifier: String, clientId: String, serial: String) async throws -> KindleDeviceCredentials {
        let body: [String: Any] = [
            "requested_token_type": ["bearer", "mac_dms", "website_cookies", "store_authentication_cookie"],
            "cookies": ["website_cookies": [], "domain": ".amazon.\(region.domainSuffix)"],
            "registration_data": [
                "domain": "Device",
                "app_version": "3.56.2",
                "device_serial": serial,
                "device_type": Self.deviceType,
                "device_name": "Flyleaf on Mac",
                "os_version": "15.0.0",
                "software_version": "35602678",
                "device_model": "iPhone",
                "app_name": "Flyleaf",
            ],
            "auth_data": [
                "client_id": clientId,
                "authorization_code": code,
                "code_verifier": verifier,
                "code_algorithm": "SHA-256",
                "client_domain": "DeviceLegacy",
            ],
            "requested_extensions": ["device_info", "customer_info"],
        ]
        var request = URLRequest(url: URL(string: "https://api.amazon.\(region.domainSuffix)/auth/register")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Flyleaf/0.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeviceAuthError.registerFailed("non-JSON, HTTP \(status)")
        }
        guard status == 200,
              let resp = json["response"] as? [String: Any],
              let success = resp["success"] as? [String: Any],
              let tokens = success["tokens"] as? [String: Any],
              let macDms = tokens["mac_dms"] as? [String: Any],
              let adpToken = macDms["adp_token"] as? String,
              let privateKey = macDms["device_private_key"] as? String else {
            let message = (json["response"] as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                ?? String(data: data.prefix(200), encoding: .utf8) ?? "unknown"
            throw DeviceAuthError.registerFailed("HTTP \(status): \(message)")
        }
        let bearer = tokens["bearer"] as? [String: Any]
        return KindleDeviceCredentials(
            adpToken: adpToken,
            devicePrivateKey: privateKey,
            accessToken: (bearer?["access_token"] as? String) ?? "",
            refreshToken: (bearer?["refresh_token"] as? String) ?? "",
            deviceSerial: serial,
            deviceType: Self.deviceType,
            registeredAt: Date()
        )
    }

    // MARK: PKCE + client id

    private static func randomSerial() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }

    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func clientId(serial: String) -> String {
        let raw = Data("\(serial)#\(deviceType)".utf8)
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class OAuthNavDelegate: NSObject, WKNavigationDelegate {
    private let onResult: (Result<String, Error>) -> Void
    private var done = false

    init(onResult: @escaping (Result<String, Error>) -> Void) {
        self.onResult = onResult
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let code = Self.extractCode(url) {
            done = true
            decisionHandler(.cancel)
            onResult(.success(code))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url, let code = Self.extractCode(url), !done {
            done = true
            onResult(.success(code))
        }
    }

    private static func extractCode(_ url: URL) -> String? {
        guard url.path.contains("/ap/maplanding") else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return comps?.queryItems?.first(where: { $0.name == "openid.oa2.authorization_code" })?.value
    }
}

// Hosts the OAuth web view only if interaction turns out to be needed.
@MainActor
final class DeviceAuthWindow {
    static let shared = DeviceAuthWindow()
    private var window: NSWindow?

    func show(webView: WKWebView) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 700),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Register this Mac with Amazon"
            w.center()
            window = w
        }
        window?.contentView = webView
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }
}
