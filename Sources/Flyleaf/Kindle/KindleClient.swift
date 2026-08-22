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
    var deviceSigner: ADPSigner?
    var deviceType: String = KindleDeviceAuth.deviceTypeConstant
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

    // GET without the JSON/sign-in heuristics, for HTML pages (the MYCD
    // console) where sign-in markers appear legitimately in the chrome.
    private func rawGet(_ url: URL) async throws -> (status: Int, body: Data) {
        var requestHeaders = await headers(for: url)
        requestHeaders["Accept"] = "text/html,application/xhtml+xml,*/*"
        if useBridge {
            requestHeaders.removeValue(forKey: "User-Agent")
            requestHeaders.removeValue(forKey: "Referer")
            return try await bridge.get(url, headers: requestHeaders)
        }
        requestHeaders["Cookie"] = await AmazonCookies.header(for: url, region: region)
        var request = URLRequest(url: url)
        for (k, v) in requestHeaders { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, data)
        } catch {
            throw KindleError.transport(error.localizedDescription)
        }
    }

    private func postForm(_ url: URL, fields: [(String, String)], referer: String? = nil) async throws -> Data {
        var requestHeaders = await headers(for: url)
        requestHeaders["Content-Type"] = "application/x-www-form-urlencoded"
        if let referer { requestHeaders["Referer"] = referer }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")

        if useBridge {
            requestHeaders.removeValue(forKey: "User-Agent")
            let (status, data) = try await bridge.post(url, headers: requestHeaders, body: body)
            return try Self.handle(status: status, body: data, url: url)
        }
        requestHeaders["Cookie"] = await AmazonCookies.header(for: url, region: region)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        for (k, v) in requestHeaders { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return try Self.handle(status: status, body: data, url: url)
        } catch let error as KindleError {
            throw error
        } catch {
            throw KindleError.transport(error.localizedDescription)
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

    // MARK: Personal documents (Send-to-Kindle)

    private var cachedCSRF: String?

    // The Manage-Your-Content console carries a CSRF token in its HTML. Cookie
    // auth only; no device registration.
    private func mycdCSRF() async throws -> String {
        if let cachedCSRF { return cachedCSRF }
        let base = region.wwwBaseURL
        let pages = [
            "hz/mycd/digital-console/contentlist/pdocsAll/dateDsc/",
            "hz/mycd/digital-console/contentlist/booksAll/dateDsc/",
            "hz/mycd/myx",
        ]
        for page in pages {
            let url = base.appendingPathComponent(page)
            let (status, data) = try await rawGet(url)
            guard status == 200, let html = String(data: data, encoding: .utf8) else {
                log(.kindle, .debug, "MYCD csrf page \(page) -> HTTP \(status)")
                continue
            }
            if let token = Self.extractCSRF(html) {
                cachedCSRF = token
                log(.kindle, "MYCD csrf token acquired via \(page)")
                return token
            }
            log(.kindle, .debug, "MYCD csrf page \(page) had no token (\(data.count) bytes)")
        }
        throw KindleError.decode("no MYCD csrf token")
    }

    nonisolated static func extractCSRF(_ html: String) -> String? {
        let patterns = [
            #"csrfToken["']?\s*[:=]\s*["']([^"']+)["']"#,
            #"name=["']csrfToken["']\s+value=["']([^"']+)["']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, range: range),
               match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: html) {
                let token = String(html[r])
                if token.count > 4 { return token }
            }
        }
        return nil
    }

    func personalDocuments() async throws -> [KindleLibraryItem] {
        let token = try await mycdCSRF()
        let activityInput: [String: Any] = [
            "contentType": "KindlePDoc",
            "contentCategoryReference": "pdocs",
            "itemStatusList": ["Active"],
            "showSharedContent": true,
            "fetchCriteria": [
                "sortOrder": "DESCENDING",
                "sortIndex": "DATE",
                "startIndex": 0,
                "batchSize": 1000,
                "totalContentCount": -1,
            ],
            "surfaceType": "LargeDesktop",
        ]
        let inputJSON = String(data: try JSONSerialization.data(withJSONObject: activityInput), encoding: .utf8) ?? "{}"
        let url = region.wwwBaseURL.appendingPathComponent("hz/mycd/digital-console/ajax")
        let data = try await postForm(
            url,
            fields: [
                ("activity", "GetContentOwnershipData"),
                ("activityInput", inputJSON),
                ("csrfToken", token),
            ],
            referer: region.wwwBaseURL.appendingPathComponent("hz/mycd/digital-console/contentlist/pdocsAll/dateDsc/").absoluteString
        )
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KindleError.decode("MYCD response not JSON: \(String(data: data.prefix(160), encoding: .utf8) ?? "")")
        }
        let success = (obj["success"] as? Bool) ?? true
        guard success else {
            throw KindleError.decode("MYCD returned success=false: \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
        let rawItems = (obj["items"] as? [[String: Any]])
            ?? ((obj["GetContentOwnershipData"] as? [String: Any])?["items"] as? [[String: Any]])
            ?? []
        return rawItems.compactMap { item -> KindleLibraryItem? in
            guard let asin = item["asin"] as? String else { return nil }
            let title = (item["title"] as? String) ?? "Untitled document"
            var authors = [String]()
            if let a = item["authors"] as? String { authors = [a] }
            else if let a = item["author"] as? String { authors = [a] }
            else if let list = item["authors"] as? [String] { authors = list }
            return KindleLibraryItem(
                asin: asin,
                title: title,
                authors: authors,
                productUrl: nil,
                percentageRead: nil,
                resourceType: "PDOC",
                originType: "Pdoc",
                webReaderUrl: nil
            )
        }
    }

    // ADP-signed requests use the device credentials, not cookies, and go to
    // a plain session (no cookie jar, no redirect guard).
    private let adpSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private func adpGet(host: String, path: String, signer: ADPSigner) async throws -> (status: Int, body: Data) {
        try await adpRequest(method: "GET", host: host, path: path, body: nil, signer: signer)
    }

    private func adpRequest(method: String, host: String, path: String, body: String?, signer: ADPSigner) async throws -> (status: Int, body: Data) {
        guard let headers = signer.headers(method: method, path: path, body: body ?? "") else {
            throw KindleError.transport("ADP signing failed")
        }
        var request = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        request.httpMethod = method
        request.setValue("Flyleaf/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.data(using: .utf8)
        }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await adpSession.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            throw KindleError.transport(error.localizedDescription)
        }
    }

    struct DocPosition {
        let asin: String
        let position: Int
        let lastRead: Date?
    }

    // Furthest-read position and when it was last updated, for one personal
    // document. Requires a registered device signer.
    func personalDocPosition(asin: String) async -> DocPosition? {
        guard let signer = deviceSigner else { return nil }
        do {
            let (_, scBody) = try await adpGet(
                host: "cde-ta-g7g.amazon.com",
                path: "/FionaCDEServiceEngine/sidecar?type=PDOC&key=\(asin)",
                signer: signer
            )
            guard !scBody.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: scBody) as? [String: Any],
                  let (pos, _) = Self.positionFromSidecarJSON(json) else { return nil }
            let lastRead = Self.lastReadTime(fromSidecar: json)
            return DocPosition(asin: asin, position: pos, lastRead: lastRead)
        } catch {
            log(.kindle, .debug, "personalDocPosition(\(asin.prefix(8))) failed: \(error)")
            return nil
        }
    }

    // Scans every personal document for its furthest-read position, newest
    // first. Heavier (one request per document), so run occasionally.
    func scanPersonalDocuments() async -> [(item: KindleLibraryItem, pos: DocPosition)] {
        guard deviceSigner != nil else { return [] }
        let docs = (try? await personalDocuments()) ?? []
        var out = [(KindleLibraryItem, DocPosition)]()
        for doc in docs {
            if let pos = await personalDocPosition(asin: doc.asin), pos.position > 0 {
                out.append((doc, pos))
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return out.sorted { ($0.1.lastRead ?? .distantPast) > ($1.1.lastRead ?? .distantPast) }
    }

    nonisolated static func lastReadTime(fromSidecar json: [String: Any]) -> Date? {
        let records = (json["payload"] as? [String: Any])?["records"] as? [[String: Any]] ?? []
        let lpr = records.first { ($0["type"] as? String)?.lowercased().contains("lpr") ?? false }
        guard let timeString = lpr?["creationTime"] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.S"
        return f.date(from: timeString)
    }

    // Reads the furthest-read position for a document via the CDE annotations
    // service, authenticated as a registered device. This is the personal-
    // document sync path. Returns the raw position and the document's end
    // position when the response provides it.
    func documentPosition(asin: String, type: String, signer: ADPSigner) async throws -> (position: Int, endPosition: Int?, raw: String) {
        let (scStatus, scBody) = try await adpGet(
            host: "cde-ta-g7g.amazon.com",
            path: "/FionaCDEServiceEngine/sidecar?type=\(type)&key=\(asin)",
            signer: signer
        )
        guard scStatus == 200, !scBody.isEmpty else {
            throw KindleError.http(status: scStatus == 200 ? 204 : scStatus)
        }
        let scText = String(data: scBody, encoding: .utf8) ?? "<\(scBody.count) bytes>"
        log(.kindle, "sidecar[\(type)] HTTP \(scStatus) \(scBody.count) bytes: \(scText.replacingOccurrences(of: "\n", with: "⏎").prefix(600))")

        // Modern sidecar is JSON and may carry the last-read position directly.
        if let json = try? JSONSerialization.jsonObject(with: scBody) as? [String: Any],
           let (pos, end) = Self.positionFromSidecarJSON(json) {
            return (pos, end, scText)
        }
        let guid = String(decoding: scBody.prefix(32), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))

        let (annStatus, annBody) = try await adpGet(
            host: "cde-ta-g7g.amazon.com",
            path: "/FionaCDEServiceEngine/getAnnotations?filter=last_read&type=\(type)&key=\(asin)&guid=\(guid)",
            signer: signer
        )
        let raw = String(data: annBody, encoding: .utf8) ?? "<\(annBody.count) binary bytes>"
        log(.kindle, "getAnnotations[\(type)] HTTP \(annStatus) guid=\(guid.prefix(12))… body=\(raw.replacingOccurrences(of: "\n", with: "⏎").prefix(500))")
        guard annStatus == 200 else {
            throw KindleError.http(status: annStatus)
        }
        let (pos, end) = Self.parseLastRead(raw)
        guard let pos else {
            throw KindleError.decode("no position in last_read response")
        }
        return (pos, end, raw)
    }

    // getAnnotations last_read returns XML with the position in a
    // <plugin ...><begin>…</begin></plugin> / <position>…</position> record.
    // Parsed leniently since the exact schema varies by content type.
    // The JSON sidecar holds annotation records; the furthest-read position
    // is a "last_read" style entry. Schema varies, so search common shapes.
    nonisolated static func positionFromSidecarJSON(_ json: [String: Any]) -> (Int, Int?)? {
        func intFrom(_ any: Any?) -> Int? {
            if let i = any as? Int { return i }
            if let n = any as? NSNumber { return n.intValue }
            if let s = any as? String { return Int(s) }
            return nil
        }
        // The furthest-read record lives in payload.records with
        // type "kindle.lpr" and the position in "location".
        let records = (json["payload"] as? [String: Any])?["records"] as? [[String: Any]]
            ?? json["records"] as? [[String: Any]]
            ?? []
        for rec in records {
            let type = (rec["type"] as? String)?.lowercased() ?? ""
            let annId = (rec["annotationId"] as? String)?.lowercased() ?? ""
            let isLPR = type.contains("lpr") || type.contains("last_read")
                || annId.contains("furthest-page-read") || annId.contains("furthest_read")
            guard isLPR else { continue }
            if let loc = intFrom(rec["location"]) ?? intFrom(rec["position"]) ?? intFrom(rec["begin"]) {
                return (loc, intFrom(rec["end"]) ?? intFrom(rec["endLocation"]))
            }
        }
        return nil
    }

    nonisolated static func parseLastRead(_ xml: String) -> (Int?, Int?) {
        func firstInt(_ patterns: [String]) -> Int? {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                let range = NSRange(xml.startIndex..., in: xml)
                if let m = regex.firstMatch(in: xml, range: range), m.numberOfRanges > 1,
                   let r = Range(m.range(at: 1), in: xml), let v = Int(xml[r]) {
                    return v
                }
            }
            return nil
        }
        let position = firstInt([
            #"<position>(\d+)</position>"#,
            #"<begin>(\d+)</begin>"#,
            #"position=["'](\d+)["']"#,
            #"lastPageRead[^>]*>(\d+)<"#,
        ])
        let end = firstInt([
            #"<end>(\d+)</end>"#,
            #"endPosition=["'](\d+)["']"#,
            #"<lpr_end>(\d+)</lpr_end>"#,
        ])
        return (position, end)
    }

    // The document's total position count, needed to turn a furthest-read
    // location into a percent. Tries the device-authenticated delivery
    // manifest and a few known shapes; returns nil if none carry it.
    func documentEndPosition(asin: String, deviceType: String, signer: ADPSigner) async throws -> Int? {
        let (status, body) = try await adpGet(
            host: "todo-ta-g7g.amazon.com",
            path: "/FionaTodoListProxy/syncMetaData?item_count=5000",
            signer: signer
        )
        guard status == 200, let xml = String(data: body, encoding: .utf8) else {
            log(.kindle, "syncMetaData HTTP \(status) \(body.count)b")
            return nil
        }
        // Log the metadata fragment around this document so its size/position
        // fields are visible.
        if let r = xml.range(of: asin) {
            let start = xml.index(r.lowerBound, offsetBy: -600, limitedBy: xml.startIndex) ?? xml.startIndex
            let end = xml.index(r.upperBound, offsetBy: 400, limitedBy: xml.endIndex) ?? xml.endIndex
            log(.kindle, "syncMetaData[\(asin.prefix(8))]: …\(xml[start..<end].replacingOccurrences(of: "\n", with: "⏎"))…")
        } else {
            log(.kindle, "syncMetaData \(body.count)b, asin not found; head=\(xml.prefix(300))")
        }
        return Self.endPositionFromMetadataXML(xml, asin: asin)
    }

    nonisolated static func endPositionFromMetadataXML(_ xml: String, asin: String) -> Int? {
        // Find the <meta_data> block for this asin, then read a size/position.
        guard let asinRange = xml.range(of: asin) else { return nil }
        let windowEnd = xml.index(asinRange.upperBound, offsetBy: 1200, limitedBy: xml.endIndex) ?? xml.endIndex
        let window = String(xml[asinRange.upperBound..<windowEnd])
        for pattern in [#"<endPosition>(\d+)</endPosition>"#, #"<Position>(\d+)</Position>"#, #"positionCount["'>]+(\d+)"#, #"<size>(\d+)</size>"#] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let m = regex.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)),
               m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: window), let v = Int(window[r]) {
                return v
            }
        }
        return nil
    }

    nonisolated static func endPositionFromManifest(_ json: [String: Any]) -> Int? {
        func intFrom(_ any: Any?) -> Int? {
            if let i = any as? Int { return i }
            if let n = any as? NSNumber { return n.intValue }
            if let s = any as? String { return Int(s) }
            return nil
        }
        for key in ["endPosition", "end_position", "maxPosition", "totalPositions", "positionCount", "lastPosition"] {
            if let v = intFrom(json[key]) { return v }
        }
        if let content = json["content"] as? [String: Any], let v = intFrom(content["endPosition"]) { return v }
        return nil
    }

    struct KindleDevice {
        let serial: String
        let deviceType: String
        let customerId: String
        let name: String
        let deviceClass: String
    }

    // Registered devices, via the classic MYCD ajax GetDevices operation.
    func devices() async throws -> [KindleDevice] {
        let token = try await mycdCSRF()
        let payload = ["param": ["GetDevices": [String: String]()]]
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"
        let url = region.wwwBaseURL.appendingPathComponent("hz/mycd/ajax")
        let data = try await postForm(
            url,
            fields: [("data", json), ("csrfToken", token)],
            referer: region.wwwBaseURL.appendingPathComponent("hz/mycd/myx").absoluteString
        )
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gd = obj["GetDevices"] as? [String: Any],
              let list = gd["devices"] as? [[String: Any]] else {
            throw KindleError.decode("GetDevices: \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
        return list.compactMap { d in
            guard let serial = d["deviceSerialNumber"] as? String else { return nil }
            return KindleDevice(
                serial: serial,
                deviceType: (d["deviceType"] as? String) ?? "",
                customerId: (d["customerId"] as? String) ?? "",
                name: (d["deviceName"] as? String) ?? "Kindle",
                deviceClass: (d["deviceClass"] as? String) ?? ""
            )
        }
    }

    // The Whispersync sidecar (annotations plus furthest-read position) for a
    // piece of content, fetched from CDE with cookie auth in the context of a
    // registered device. This is the personal-document position path.
    func fetchSidecar(asin: String, type: String, device: KindleDevice) async throws -> (status: Int, body: Data) {
        var comps = URLComponents(string: "https://cde-ta-g7g.amazon.com/FionaCDEServiceEngine/sidecar")!
        var items = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "key", value: asin),
            URLQueryItem(name: "fsn", value: device.serial),
            URLQueryItem(name: "device_type", value: device.deviceType),
        ]
        if !device.customerId.isEmpty {
            items.append(URLQueryItem(name: "customerId", value: device.customerId))
        }
        if let pool = region.cdeAuthPool {
            items.append(URLQueryItem(name: "authPool", value: pool))
        }
        comps.queryItems = items
        return try await rawGet(comps.url!)
    }

    // Developer diagnostics (flyleaf://diag?q=term): lists personal documents
    // via MYCD, then probes whether the web reader exposes a synced position
    // for a matching one. Determines if cookie-only sync is possible for
    // Send-to-Kindle books. Results go to the log.
    func runLibraryDiagnostics(searchTerm: String) async {
        log(.kindle, "DIAG start, searching personal documents for '\(searchTerm)'")
        do {
            let docs = try await personalDocuments()
            log(.kindle, "DIAG MYCD returned \(docs.count) personal documents")
            for doc in docs.prefix(12) {
                log(.kindle, "DIAG    PDOC '\(doc.title)' asin=\(doc.asin) by \(doc.normalizedAuthors.joined(separator: "/"))")
            }
            let matches = docs.filter { $0.title.localizedCaseInsensitiveContains(searchTerm) }
            log(.kindle, "DIAG \(matches.count) personal-document match(es) for '\(searchTerm)'")
            for doc in matches {
                await probePosition(asin: doc.asin, title: doc.title)
            }
            if matches.isEmpty, let first = docs.first {
                log(.kindle, "DIAG no title match; probing most recent PDOC as a control")
                await probePosition(asin: first.asin, title: first.title)
            }
        } catch {
            log(.kindle, "DIAG personalDocuments failed: \(error)")
        }
        await probeWhispersyncControl()
        log(.kindle, "DIAG done")
    }

    // Tries every plausible read-only way to read a synced position for an
    // ASIN, logging what each returns.
    private func probePosition(asin: String, title: String) async {
        log(.kindle, "DIAG probing position for '\(title)' (\(asin))")
        do {
            let info = try await startReading(asin: asin)
            let position = info.lastPageReadData?.position.map(String.init) ?? "none"
            let device = info.lastPageReadData?.deviceName ?? "none"
            log(.kindle, "DIAG    startReading: position=\(position) device=\(device) metadataUrl=\(info.metadataUrl != nil) owned=\(info.isOwned ?? false)")
        } catch {
            log(.kindle, "DIAG    startReading failed: \(error)")
        }

        // The real path for personal documents: CDE sidecar with a registered
        // device's identifiers, cookie-authenticated. Personal docs are
        // delivered per-device, so try every device and every content type.
        do {
            let devices = try await devices()
            let readers = devices.filter { !$0.serial.isEmpty && $0.deviceType.hasPrefix("A") }
            log(.kindle, "DIAG    \(devices.count) devices, \(readers.count) with a serial")
            var nonEmpty = 0
            for type in ["PDOC", "EBOK", "EBSP"] {
                var emptyCount = 0
                for device in readers {
                    do {
                        let (status, body) = try await fetchSidecar(asin: asin, type: type, device: device)
                        if status == 200 && body.isEmpty {
                            emptyCount += 1
                            continue
                        }
                        nonEmpty += 1
                        let text = String(data: body.prefix(300), encoding: .utf8) ?? ""
                        let b64 = body.prefix(64).base64EncodedString()
                        log(.kindle, "DIAG    *** sidecar type=\(type) via '\(device.name)' [\(device.deviceType)]: HTTP \(status), \(body.count) bytes, head64=\(b64) text=\(text.replacingOccurrences(of: "\n", with: "⏎").prefix(200))")
                    } catch {
                        log(.kindle, "DIAG    sidecar type=\(type) via '\(device.name)' failed: \(error)")
                    }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
                log(.kindle, "DIAG    type=\(type): \(emptyCount) empty of \(readers.count)")
            }
            log(.kindle, "DIAG    sidecar probe found \(nonEmpty) non-empty responses")
        } catch {
            log(.kindle, "DIAG    devices/sidecar probe failed: \(error)")
        }
    }

    // Control: for an owned book that DOES have a synced position (via
    // startReading), does the cookie-authenticated CDE sidecar return
    // anything? Determines whether the sidecar is a viable position source at
    // all, or whether device (ADP) auth is required.
    func probeWhispersyncControl() async {
        do {
            let items = try await library()
            let devices = (try? await devices()) ?? []
            log(.kindle, "DIAG CONTROL scanning owned books for a synced position, \(devices.count) devices available")
            var checkedSidecar = 0
            for item in items.prefix(20) {
                guard checkedSidecar < 2 else { break }
                do {
                    let info = try await startReading(asin: item.asin)
                    guard let pos = info.lastPageReadData?.position, pos > 0 else { continue }
                    let syncDevice = info.lastPageReadData?.deviceName ?? "?"
                    log(.kindle, "DIAG CONTROL '\(item.title)': startReading position=\(pos) device=\(syncDevice)")
                    checkedSidecar += 1
                    // Does the cookie sidecar return this position for an owned book?
                    for device in devices.prefix(6) {
                        let (status, body) = try await fetchSidecar(asin: item.asin, type: "EBOK", device: device)
                        if status == 200 && body.isEmpty { continue }
                        let b64 = body.prefix(80).base64EncodedString()
                        log(.kindle, "DIAG CONTROL   sidecar via '\(device.name)': HTTP \(status), \(body.count) bytes, head=\(b64)")
                        break
                    }
                } catch {}
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            log(.kindle, "DIAG CONTROL done")
        } catch {
            log(.kindle, "DIAG CONTROL failed: \(error)")
        }
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
