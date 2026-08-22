import Foundation

struct BookRef: Codable, Equatable, Identifiable, Hashable {
    var id: String { asin }
    let asin: String
    var title: String
    var authors: [String]
    var coverURL: URL?
    var isManual: Bool
    var isPersonalDoc: Bool = false

    var authorLine: String { authors.joined(separator: ", ") }

    static func manual(title: String, author: String, asin: String?) -> BookRef {
        let cleanASIN = asin?.trimmingCharacters(in: .whitespaces)
        let key: String
        if let cleanASIN, !cleanASIN.isEmpty {
            key = cleanASIN
        } else {
            let slug = title.lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            key = "manual:\(slug)"
        }
        return BookRef(
            asin: key,
            title: title,
            authors: author.isEmpty ? [] : [author],
            coverURL: nil,
            isManual: true
        )
    }

    // A book whose position Flyleaf follows automatically but whose progress
    // comes from Whispersync-for-Documents rather than the reader API.
    var syncsAutomatically: Bool { !isManual || isPersonalDoc }
}

struct ReadingPosition: Codable, Equatable {
    var percent: Double
    var syncedAt: Date
    var deviceName: String?
    var kindlePosition: Int?
}

struct TOCChapter: Codable, Equatable, Identifiable {
    var id: Int { index }
    let index: Int
    var title: String
    var startPercent: Double
}

struct BookTOC: Codable, Equatable {
    var chapters: [TOCChapter]
    var source: String

    func chapterIndex(forPercent percent: Double) -> Int? {
        let sorted = chapters.sorted { $0.startPercent < $1.startPercent }
        guard let match = sorted.last(where: { $0.startPercent <= percent + 0.0001 }) else {
            return sorted.first?.index
        }
        return match.index
    }

    func chapter(_ index: Int) -> TOCChapter? {
        chapters.first { $0.index == index }
    }

    var maxChapter: Int { chapters.map(\.index).max() ?? 1 }
}

enum EntityKind: String, Codable, CaseIterable {
    case person, place, organization, product, term, event

    var label: String {
        switch self {
        case .person: return "Person"
        case .place: return "Place"
        case .organization: return "Organization"
        case .product: return "Product"
        case .term: return "Term"
        case .event: return "Event"
        }
    }

    var symbolName: String {
        switch self {
        case .person: return "person.crop.circle"
        case .place: return "mappin.and.ellipse"
        case .organization: return "building.2"
        case .product: return "shippingbox"
        case .term: return "character.book.closed"
        case .event: return "calendar"
        }
    }
}

struct Entity: Codable, Identifiable, Equatable, Hashable {
    var id: String { "\(kind.rawValue):\(name)" }
    var kind: EntityKind
    var name: String
    var oneLiner: String
    var detail: String?
    var wikipediaTitle: String?
    var imageURL: URL?
    var latitude: Double?
    var longitude: Double?
    var firstMentionChapter: Int?
    var affiliation: String?
    var pronunciation: String?
    var thenNow: String?
    var sourceURLs: [URL]
    var rank: Int
    var dateText: String?
    var sortDate: String?

    var hasCoordinates: Bool { latitude != nil && longitude != nil }
}

struct ContextPack: Codable, Equatable {
    var asin: String
    var chapter: Int
    var chapterTitle: String
    var packVersion: Int
    var briefing: String?
    var entities: [Entity]
    var builtAt: Date

    static let currentVersion = 1
}

enum PackStatus: Equatable {
    case none
    case building(String)
    case ready
    case failed(String)
    case needsKey
}

struct PositionSample: Codable, Equatable {
    var asin: String
    var percent: Double
    var at: Date
    var source: String
}

struct ManualPin: Codable, Equatable {
    var chapter: Int
    var percentAtPin: Double
}

enum ConnectionState: Equatable {
    case notConnected
    case connecting
    case connected
    case needsReauth
}
