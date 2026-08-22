import Foundation

// Enriches entities with openly licensed imagery, descriptions, and
// coordinates from the Wikipedia REST summary endpoint. This keeps images on
// Wikimedia infrastructure and satisfies the licensing stance in the spec.
final class WikipediaResolver: @unchecked Sendable {
    struct Summary {
        var title: String
        var description: String?
        var extract: String?
        var thumbnailURL: URL?
        var latitude: Double?
        var longitude: Double?
        var pageURL: URL?
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "Flyleaf/0.1 (macOS personal build)"]
        session = URLSession(configuration: config)
    }

    func summary(forTitle title: String) async -> Summary? {
        let normalized = title.replacingOccurrences(of: " ", with: "_")
        guard let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)?redirect=true") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if json["type"] as? String == "disambiguation" { return nil }
            var s = Summary(title: json["title"] as? String ?? title)
            s.description = json["description"] as? String
            s.extract = json["extract"] as? String
            if let thumb = json["thumbnail"] as? [String: Any], let src = thumb["source"] as? String {
                s.thumbnailURL = URL(string: src)
            }
            if let coords = json["coordinates"] as? [String: Any] {
                s.latitude = (coords["lat"] as? NSNumber)?.doubleValue
                s.longitude = (coords["lon"] as? NSNumber)?.doubleValue
            }
            if let urls = json["content_urls"] as? [String: Any],
               let desktop = urls["desktop"] as? [String: Any],
               let page = desktop["page"] as? String {
                s.pageURL = URL(string: page)
            }
            return s
        } catch {
            log(.wiki, .warn, "Summary fetch failed for \(title): \(error.localizedDescription)")
            return nil
        }
    }

    func enrich(_ pack: ContextPack) async -> ContextPack {
        var enriched = pack
        for (i, entity) in enriched.entities.enumerated() {
            guard let title = entity.wikipediaTitle, !title.isEmpty else { continue }
            guard let summary = await summary(forTitle: title) else { continue }
            var e = entity
            if e.imageURL == nil { e.imageURL = summary.thumbnailURL }
            if e.latitude == nil { e.latitude = summary.latitude }
            if e.longitude == nil { e.longitude = summary.longitude }
            if let page = summary.pageURL, !e.sourceURLs.contains(page) {
                e.sourceURLs.append(page)
            }
            enriched.entities[i] = e
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return enriched
    }
}
