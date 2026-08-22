import Foundation
import WebKit

// Cookies live in the shared WKWebsiteDataStore, written by the embedded
// Amazon sign-in page and persisted by WebKit across launches. That store is
// the single source of truth; URLSession requests read from it before every
// batch so rotated cookies are always current.
@MainActor
enum AmazonCookies {
    static func all(region: AmazonRegion) async -> [HTTPCookie] {
        let suffix = "amazon.\(region.domainSuffix)"
        func matches(_ cookie: HTTPCookie) -> Bool {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return domain == suffix || domain.hasSuffix(".\(suffix)") || domain == "read.\(suffix)"
        }

        // Two jars, one truth. WKHTTPCookieStore only answers once a webview
        // has attached WebKit's network process, so on a fresh launch with no
        // login window it reports empty. The Foundation jar is the same
        // persistent store (WebKit bridges into it for non-sandboxed apps)
        // and reads fine without any webview, so merge both, WebKit winning.
        for attempt in 0..<2 {
            var merged = [String: HTTPCookie]()
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where matches(cookie) {
                merged["\(cookie.domain)|\(cookie.name)|\(cookie.path)"] = cookie
            }
            let store = WKWebsiteDataStore.default().httpCookieStore
            for cookie in await store.allCookies() where matches(cookie) {
                merged["\(cookie.domain)|\(cookie.name)|\(cookie.path)"] = cookie
            }
            if !merged.isEmpty { return Array(merged.values) }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        return []
    }

    static func header(for url: URL, region: AmazonRegion) async -> String {
        let cookies = await all(region: region)
        let applicable = cookies.filter { cookie in
            guard let host = url.host else { return false }
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix(".\(domain)")
        }
        return applicable.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    static func value(named name: String, region: AmazonRegion) async -> String? {
        await all(region: region).first { $0.name == name }?.value
    }

    static func hasSessionCookies(region: AmazonRegion) async -> Bool {
        let cookies = await all(region: region)
        let hasAuthToken = cookies.contains { $0.name.hasPrefix("at-") && !$0.value.isEmpty }
        let hasUbid = cookies.contains { $0.name.hasPrefix("ubid-") && !$0.value.isEmpty }
        return hasAuthToken && hasUbid
    }

    static func clear() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let amazonRecords = records.filter { $0.displayName.contains("amazon") }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: amazonRecords)
    }
}
