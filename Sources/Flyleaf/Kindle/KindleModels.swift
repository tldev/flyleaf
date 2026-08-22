import Foundation

struct KindleLibraryItem: Decodable {
    let asin: String
    let title: String
    let authors: [String]?
    let productUrl: String?
    let percentageRead: Double?
    let resourceType: String?
    let originType: String?
    let webReaderUrl: String?

    // Amazon serializes authors like "McGee, Patrick:" with colon separators.
    var normalizedAuthors: [String] {
        (authors ?? [])
            .flatMap { $0.components(separatedBy: ":") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var bookRef: BookRef {
        BookRef(
            asin: asin,
            title: title,
            authors: normalizedAuthors,
            coverURL: productUrl.flatMap(URL.init(string:)),
            isManual: false
        )
    }
}

struct KindleLibraryResponse: Decodable {
    let itemsList: [KindleLibraryItem]?
    let paginationToken: String?

    var items: [KindleLibraryItem] { itemsList ?? [] }
}

struct DeviceTokenResponse: Decodable {
    let deviceSessionToken: String
}

struct LastPageReadData: Decodable {
    let deviceName: String?
    let position: Int?
    let syncTime: Double?

    var syncDate: Date? {
        guard let syncTime else { return nil }
        // Amazon sends epoch milliseconds.
        return Date(timeIntervalSince1970: syncTime > 10_000_000_000 ? syncTime / 1000 : syncTime)
    }
}

struct StartReadingResponse: Decodable {
    let contentVersion: String?
    let formatVersion: String?
    let kindleSessionId: String?
    let lastPageReadData: LastPageReadData?
    let metadataUrl: String?
    let isSample: Bool?
    let isOwned: Bool?
    let srl: Int?
}

struct BookMetadata {
    var startPosition: Int?
    var endPosition: Int?
    var releaseDate: String?
    var publisher: String?
    var toc: [(title: String, position: Int)]

    func percent(forPosition position: Int) -> Double? {
        guard let endPosition, endPosition > 0 else { return nil }
        let start = startPosition ?? 0
        guard endPosition > start else { return nil }
        let fraction = Double(position - start) / Double(endPosition - start)
        return max(0, min(100, fraction * 100))
    }

    // Some books expose a nav TOC in delivery metadata. When present it gives
    // exact chapter boundaries and beats any reconstructed TOC.
    func bookTOC() -> BookTOC? {
        guard toc.count >= 3, let endPosition, endPosition > 0 else { return nil }
        let start = startPosition ?? 0
        guard endPosition > start else { return nil }
        var chapters = [TOCChapter]()
        for (i, entry) in toc.enumerated() {
            let fraction = Double(entry.position - start) / Double(endPosition - start)
            chapters.append(TOCChapter(
                index: i + 1,
                title: entry.title,
                startPercent: max(0, min(100, fraction * 100))
            ))
        }
        return BookTOC(chapters: chapters, source: "kindle-metadata")
    }
}

enum KindleError: Error, CustomStringConvertible {
    case notSignedIn
    case botWall(status: Int)
    case http(status: Int)
    case decode(String)
    case transport(String)

    var description: String {
        switch self {
        case .notSignedIn: return "Amazon session expired or not signed in"
        case .botWall(let s): return "Amazon returned a bot challenge (HTTP \(s))"
        case .http(let s): return "Amazon returned HTTP \(s)"
        case .decode(let m): return "Could not parse Amazon response: \(m)"
        case .transport(let m): return "Network error: \(m)"
        }
    }

    var isAuthFailure: Bool {
        if case .notSignedIn = self { return true }
        if case .http(let s) = self, s == 401 || s == 403 { return true }
        return false
    }
}
