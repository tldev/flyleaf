import Foundation
import WebKit

// Fallback transport: a hidden WKWebView parked on a tiny same-origin page,
// issuing fetch() calls with WebKit's own TLS fingerprint and cookie jar.
// Used automatically if plain URLSession requests hit Amazon's bot wall.
@MainActor
final class WebViewBridge: NSObject {
    private var webView: WKWebView?
    private var readyHost: String?

    private func preparedWebView(for baseURL: URL) async throws -> WKWebView {
        if let webView, readyHost == baseURL.host {
            return webView
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        webView = wv
        readyHost = nil

        let anchor = baseURL.appendingPathComponent("robots.txt")
        wv.load(URLRequest(url: anchor))
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !wv.isLoading, wv.url?.host == baseURL.host {
                readyHost = baseURL.host
                log(.kindle, "WebView bridge ready on \(baseURL.host ?? "?")")
                return wv
            }
        }
        throw KindleError.transport("WebView bridge failed to load anchor page")
    }

    func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, body: Data) {
        let wv = try await preparedWebView(for: URL(string: "https://\(url.host ?? "read.amazon.com")")!)
        let js = """
        const res = await fetch(target, { method: "GET", credentials: "include", headers: hdrs });
        const text = await res.text();
        return { status: res.status, body: text };
        """
        do {
            let result = try await wv.callAsyncJavaScript(
                js,
                arguments: ["target": url.absoluteString, "hdrs": headers],
                in: nil,
                contentWorld: .defaultClient
            )
            guard let dict = result as? [String: Any],
                  let status = dict["status"] as? Int,
                  let body = dict["body"] as? String else {
                throw KindleError.transport("WebView bridge returned unexpected shape")
            }
            return (status, Data(body.utf8))
        } catch let error as KindleError {
            throw error
        } catch {
            throw KindleError.transport("WebView bridge: \(error.localizedDescription)")
        }
    }

    func post(_ url: URL, headers: [String: String], body: String) async throws -> (status: Int, body: Data) {
        let wv = try await preparedWebView(for: URL(string: "https://\(url.host ?? "www.amazon.com")")!)
        let js = """
        const res = await fetch(target, { method: "POST", credentials: "include", headers: hdrs, body: payload });
        const text = await res.text();
        return { status: res.status, body: text };
        """
        do {
            let result = try await wv.callAsyncJavaScript(
                js,
                arguments: ["target": url.absoluteString, "hdrs": headers, "payload": body],
                in: nil,
                contentWorld: .defaultClient
            )
            guard let dict = result as? [String: Any],
                  let status = dict["status"] as? Int,
                  let text = dict["body"] as? String else {
                throw KindleError.transport("WebView bridge POST returned unexpected shape")
            }
            return (status, Data(text.utf8))
        } catch let error as KindleError {
            throw error
        } catch {
            throw KindleError.transport("WebView bridge POST: \(error.localizedDescription)")
        }
    }

    func reset() {
        webView = nil
        readyHost = nil
    }
}
