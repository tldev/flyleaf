import Foundation
import WebKit

// Client for the same private endpoints the official Kindle web reader uses.
// Read only and low volume: library listing for position polling, plus a
// one-off startReading call per book for sync details. Never touches book
// content, DRM, or the renderer.
@MainActor
final class KindleClient {
    static let cloudReaderDeviceType = "A2CTZ977SKFQZY"
    static let clientVersion = "20000100"
    static let fallbackUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    private let region: AmazonRegion
    private var adpSessionToken: String?
    private var useBridge = false
    private let bridge = WebViewBridge()
    private let session: URLSession
    private let redirectGuard = RedirectGuard()

    var baseURL: URL { region.readerBaseURL }

    init(region: AmazonRegion) {
        self.region = region
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: redirectGuard, delegateQueue: nil)
    }

    private var userAgent: String {
        Prefs.shared.capturedUserAgent ?? Self.fallbackUserAgent
    }

    // MARK: Requests

    private func headers(for url: URL) async -> [String: String] {
        var h: [String: String] = [
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "User-Agent": userAgent,
            "Referer": baseURL.absoluteString + "/",
        ]
        if let sessionId = await AmazonCookies.value(named: "session-id", region: region) {
            h["x-amzn-sessionid"] = sessionId
        }
        if let adpSessionToken {
            h["x-adp-session-token"] = adpSessionToken
        }
        return h
    }

    private func get(_ url: URL) async throws -> Data {
        var requestHeaders = await headers(for: url)

        if useBridge {
            // Bridge fetches are same-origin: cookies ride along automatically
            // and the browser refuses manual Cookie/User-Agent headers.
            requestHeaders.removeValue(forKey: "User-Agent")
            requestHeaders.removeValue(forKey: "Referer")
            let (status, body) = try await bridge.get(url, headers: requestHeaders)
            return try Self.handle(status: status, body: body, url: url)
        }

        let cookieHeader = await AmazonCookies.header(for: url, region: region)
        requestHeaders["Cookie"] = cookieHeader
        let cookieNames = cookieHeader.split(separator: ";").compactMap { $0.split(separator: "=").first?.trimmingCharacters(in: .whitespaces) }
        log(.kindle, .debug, "GET \(url.path) with \(cookieNames.count) cookies [\(cookieNames.sorted().joined(separator: ","))]")
        var request = URLRequest(url: url)
        for (k, v) in requestHeaders { request.setValue(v, forHTTPHeaderField: k) }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw KindleError.transport("no HTTP response")
            }
            if http.statusCode >= 300 && http.statusCode < 400 {
                let location = http.value(forHTTPHeaderField: "Location") ?? ""
                log(.kindle, .warn, "Redirected away from \(url.path) to \(location)")
                throw KindleError.notSignedIn
            }
            do {
                return try Self.handle(status: http.statusCode, body: data, url: url)
            } catch let error as KindleError {
                if case .botWall = error {
                    log(.kindle, .warn, "Bot wall from URLSession transport, switching to WebView bridge")
                    useBridge = true
                    return try await get(url)
                }
                throw error
            }
        } catch let error as KindleError {
            throw error
        } catch {
            throw KindleError.transport(error.localizedDescription)
        }
    }

    private static func handle(status: Int, body: Data, url: URL) throws -> Data {
        let snippet = String(data: body.prefix(400), encoding: .utf8) ?? ""
        switch status {
        case 200:
            let looksLikeChallenge = snippet.contains("Robot Check")
                || snippet.contains("captcha")
                || snippet.contains("api-services-support@amazon.com")
            if looksLikeChallenge {
                throw KindleError.botWall(status: status)
            }
            let looksLikeSignIn = snippet.contains("ap/signin") || snippet.contains("Sign-In")
            if looksLikeSignIn, snippet.lowercased().contains("<html") {
                throw KindleError.notSignedIn
            }
            return body
        case 401:
            throw KindleError.notSignedIn
        case 403, 503:
            let looksLikeChallenge = snippet.contains("captcha") || snippet.contains("Robot Check") || snippet.isEmpty
            if looksLikeChallenge {
                throw KindleError.botWall(status: status)
            }
            log(.kindle, .warn, "HTTP \(status) from \(url.path): \(snippet.prefix(200))")
            throw KindleError.http(status: status)
        default:
            log(.kindle, .warn, "HTTP \(status) from \(url.path): \(snippet.prefix(200))")
            throw KindleError.http(status: status)
        }
    }

    // MARK: Endpoints

    // The web reader registration handshake. Yields the ADP session token that
    // subsequent API calls carry in x-adp-session-token.
    func registerDevice() async throws {
        var comps = URLComponents(url: baseURL.appendingPathComponent("service/web/register/getDeviceToken"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "serialNumber", value: Self.cloudReaderDeviceType),
            URLQueryItem(name: "deviceType", value: Self.cloudReaderDeviceType),
        ]
        let data = try await get(comps.url!)
        do {
            let token = try JSONDecoder().decode(DeviceTokenResponse.self, from: data)
            adpSessionToken = token.deviceSessionToken
            log(.kindle, "Registered reader device, session token acquired")
        } catch {
            throw KindleError.decode("getDeviceToken: \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
    }

    func library(fetchAll: Bool = false) async throws -> [KindleLibraryItem] {
        if adpSessionToken == nil {
            try await registerDevice()
        }
        var items = [KindleLibraryItem]()
        var paginationToken: String? = nil
        repeat {
            var comps = URLComponents(url: baseURL.appendingPathComponent("kindle-library/search"), resolvingAgainstBaseURL: false)!
            var query = [
                URLQueryItem(name: "query", value: ""),
                URLQueryItem(name: "libraryType", value: "BOOKS"),
                URLQueryItem(name: "sortType", value: "recency"),
                URLQueryItem(name: "querySize", value: "50"),
            ]
            if let paginationToken {
                query.append(URLQueryItem(name: "paginationToken", value: paginationToken))
            }
            comps.queryItems = query
            let data = try await get(comps.url!)
            do {
                let page = try JSONDecoder().decode(KindleLibraryResponse.self, from: data)
                items.append(contentsOf: page.items)
                paginationToken = page.paginationToken
            } catch {
                throw KindleError.decode("library: \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
            }
        } while fetchAll && paginationToken != nil
        return items
    }

    func startReading(asin: String) async throws -> StartReadingResponse {
        if adpSessionToken == nil {
            try await registerDevice()
        }
        var comps = URLComponents(url: baseURL.appendingPathComponent("service/mobile/reader/startReading"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "asin", value: asin),
            URLQueryItem(name: "clientVersion", value: Self.clientVersion),
        ]
        let data = try await get(comps.url!)
        do {
            return try JSONDecoder().decode(StartReadingResponse.self, from: data)
        } catch {
            throw KindleError.decode("startReading: \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
    }

    // Delivery metadata JSONP. Metadata only (positions, publisher, nav TOC
    // when present); never the book text.
    func metadata(from urlString: String) async throws -> BookMetadata {
        guard let url = URL(string: urlString) else {
            throw KindleError.transport("bad metadata URL")
        }
        let data = try await get(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw KindleError.decode("metadata not UTF-8")
        }
        return try Self.parseMetadataJSONP(text)
    }

    nonisolated static func parseMetadataJSONP(_ text: String) throws -> BookMetadata {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") , open < close else {
            throw KindleError.decode("metadata is not JSONP")
        }
        let jsonText = String(text[text.index(after: open)..<close])
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KindleError.decode("metadata JSON parse failed")
        }
        var meta = BookMetadata(startPosition: nil, endPosition: nil, releaseDate: nil, publisher: nil, toc: [])
        meta.startPosition = (obj["startPosition"] as? NSNumber)?.intValue
        meta.endPosition = (obj["endPosition"] as? NSNumber)?.intValue
        meta.releaseDate = obj["releaseDate"] as? String
        meta.publisher = obj["publisher"] as? String
        if let toc = obj["toc"] as? [[String: Any]] {
            meta.toc = toc.compactMap { entry in
                guard let title = entry["title"] as? String,
                      let position = (entry["position"] as? NSNumber)?.intValue else { return nil }
                return (title, position)
            }
        }
        return meta
    }

    func verifySession() async throws -> Int {
        try await registerDevice()
        let items = try await library()
        return items.count
    }

    // Developer diagnostics (flyleaf://diag?q=term): probes library endpoint
    // variants to see what the account can actually enumerate, most usefully
    // whether Send-to-Kindle personal documents appear anywhere, and whether
    // Whispersync position exists for a matched item. Results go to the log.
    func runLibraryDiagnostics(searchTerm: String) async {
        log(.kindle, "DIAG start, searching for '\(searchTerm)'")
        if adpSessionToken == nil {
            do { try await registerDevice() } catch {
                log(.kindle, "DIAG registerDevice failed: \(error)")
                return
            }
        }

        let variants: [(label: String, params: [(String, String)])] = [
            ("BOOKS recency", [("query", ""), ("libraryType", "BOOKS"), ("sortType", "recency"), ("querySize", "50")]),
            ("BOOKS title search", [("query", searchTerm), ("libraryType", "BOOKS"), ("sortType", "recency"), ("querySize", "50")]),
            ("no libraryType", [("query", ""), ("sortType", "recency"), ("querySize", "50")]),
            ("libraryType PDOCS", [("query", ""), ("libraryType", "PDOCS"), ("sortType", "recency"), ("querySize", "50")]),
            ("libraryType DOCS", [("query", ""), ("libraryType", "DOCS"), ("sortType", "recency"), ("querySize", "50")]),
            ("resourceType PDOC", [("query", ""), ("libraryType", "BOOKS"), ("resourceType", "PDOC"), ("sortType", "recency"), ("querySize", "50")]),
            ("resourceType EBOOK+PDOC", [("query", ""), ("libraryType", "BOOKS"), ("resourceType", "EBOOK,PDOC"), ("sortType", "recency"), ("querySize", "50")]),
        ]

        var matchedASINs = [String: String]()

        for variant in variants {
            var comps = URLComponents(url: baseURL.appendingPathComponent("kindle-library/search"), resolvingAgainstBaseURL: false)!
            comps.queryItems = variant.params.map { URLQueryItem(name: $0.0, value: $0.1) }
            do {
                let data = try await get(comps.url!)
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let snippet = String(data: data.prefix(160), encoding: .utf8) ?? "?"
                    log(.kindle, "DIAG [\(variant.label)]: non-JSON response: \(snippet)")
                    continue
                }
                let items = obj["itemsList"] as? [[String: Any]] ?? []
                let extraKeys = Set(obj.keys).subtracting(["itemsList", "paginationToken", "sortType"])
                log(.kindle, "DIAG [\(variant.label)]: \(items.count) items\(extraKeys.isEmpty ? "" : ", extra keys: \(extraKeys.sorted())")")
                for item in items.prefix(6) {
                    let title = item["title"] as? String ?? "?"
                    let rtype = item["resourceType"] as? String ?? "?"
                    let origin = item["originType"] as? String ?? "?"
                    let percent = (item["percentageRead"] as? NSNumber)?.stringValue ?? "-"
                    log(.kindle, "DIAG    \(title) | type=\(rtype) origin=\(origin) read=\(percent)%")
                }
                for item in items {
                    guard let title = item["title"] as? String,
                          title.localizedCaseInsensitiveContains(searchTerm),
                          let asin = item["asin"] as? String else { continue }
                    matchedASINs[asin] = title
                    log(.kindle, "DIAG    MATCH in [\(variant.label)]: \(item)")
                }
            } catch {
                log(.kindle, "DIAG [\(variant.label)]: \(error)")
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        for (asin, title) in matchedASINs {
            do {
                let info = try await startReading(asin: asin)
                let position = info.lastPageReadData?.position.map(String.init) ?? "none"
                let device = info.lastPageReadData?.deviceName ?? "none"
                log(.kindle, "DIAG startReading '\(title)': position=\(position) device=\(device) metadataUrl=\(info.metadataUrl != nil)")
            } catch {
                log(.kindle, "DIAG startReading '\(title)' failed: \(error)")
            }
        }
        log(.kindle, "DIAG done (\(matchedASINs.count) matches for '\(searchTerm)')")
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Any redirect off the reader host means the session bounced us to
        // sign-in. Surface the 3xx instead of following it.
        let originalHost = task.originalRequest?.url?.host
        if request.url?.host != originalHost || (request.url?.path.contains("/ap/signin") ?? false) {
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }
}
