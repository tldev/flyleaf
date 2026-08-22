import Foundation
import WebKit

// Cookies live in the shared WKWebsiteDataStore, written by the embedded
// Amazon sign-in page and persisted by WebKit across launches. That store is
// the single source of truth; URLSession requests read from it before every
// batch so rotated cookies are always current.
@MainActor
enum AmazonCookies {
    static func all(region: AmazonRegion) async -> [HTTPCookie] {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        let suffix = "amazon.\(region.domainSuffix)"
        return cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return domain == suffix || domain.hasSuffix(".\(suffix)") || domain == "read.\(suffix)"
        }
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
