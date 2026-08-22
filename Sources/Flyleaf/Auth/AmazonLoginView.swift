import SwiftUI
import WebKit

// Amazon's real sign-in page in an embedded web view: 2FA, passkeys, and
// CAPTCHA all behave normally, and the password never touches Flyleaf. On
// success we only keep WebKit's session cookies.
struct AmazonLoginWebView: NSViewRepresentable {
    let region: AmazonRegion
    let onAuthenticated: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(region: region, onAuthenticated: onAuthenticated)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: region.readerBaseURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let region: AmazonRegion
        let onAuthenticated: @MainActor () -> Void
        private var finished = false

        init(region: AmazonRegion, onAuthenticated: @escaping @MainActor () -> Void) {
            self.region = region
            self.onAuthenticated = onAuthenticated
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                await self.checkAuthentication(webView)
            }
        }

        private func checkAuthentication(_ webView: WKWebView) async {
            guard !finished else { return }
            guard let host = webView.url?.host, host.hasPrefix("read.amazon") else {
                log(.auth, .debug, "Login navigation: \(webView.url?.absoluteString ?? "?")")
                return
            }
            guard await AmazonCookies.hasSessionCookies(region: region) else { return }
            finished = true
            if let ua = try? await webView.evaluateJavaScript("navigator.userAgent") as? String {
                Prefs.shared.capturedUserAgent = ua
            }
            log(.auth, "Amazon sign-in detected on \(host)")
            onAuthenticated()
        }
    }
}

// Re-auth flow outside onboarding: menu bar badge opens this window.
struct StandaloneLoginView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            AmazonLoginWebView(region: Prefs.shared.region) {
                state.connectKindle()
                WindowManager.shared.close(id: "login")
            }
            Divider()
            HStack {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text("This is Amazon's own sign-in page. Flyleaf keeps only the session, never your password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    WindowManager.shared.close(id: "login")
                }
            }
            .padding(12)
        }
    }
}
