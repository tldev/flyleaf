import Foundation

// Builds a context pack from the actual chapter text of a locally imported
// book, using a cheap extraction model (OpenRouter). The text names the
// entities; Wikipedia supplies photos and coordinates. No web research call
// and no reliance on the model already knowing the book, so it works for any
// book, obscure ones included, and is genuinely spoiler-safe: only text up to
// the reader's position is ever sent.
final class LocalPackBuilder: @unchecked Sendable {
    private let client: OpenRouterClient
    private let maxChars = 22000

    init(client: OpenRouterClient) {
        self.client = client
    }

    func buildPack(
        book: BookRef,
        chapter: Int,
        chapterTitle: String,
        chapterText: String,
        previousEntityNames: [String]
    ) async throws -> ContextPack {
        let text = String(chapterText.prefix(maxChars))
        let known = previousEntityNames.isEmpty ? "none yet" : previousEntityNames.prefix(50).joined(separator: ", ")

        let system = """
        You extract the notable entities from one chapter of a book, for a glanceable reading \
        companion that shows cards about who, where, and what the reader is currently reading about.

        Work ONLY from the chapter text provided. List the people, places, organizations, products, \
        and important terms that actually appear in this text, plus any dated real-world events it \
        describes. Do not add entities that are not in this passage. Order them by how central they \
        are to this chapter, most important first, 4 to 10 total.

        For each entity give:
        - kind: person, place, organization, product, term, or event
        - oneLiner: one plain-language line under 140 characters, readable at arm's length, combining \
        the text with widely known facts
        - detail: one or two more sentences, or null
        - wikipediaTitle: the exact English Wikipedia article title if one clearly exists, else null. \
        Do not guess; use null when unsure.
        - latitude and longitude for places, else null
        - affiliation for people (their company, institution, or movement), else null
        - firstMentionChapter: use \(chapter) unless the entity is in the "already introduced" list
        - pronunciation: a phonetic respelling only for names an English speaker would stumble on \
        (like "jung-JOH" for Zhengzhou), else null
        - thenNow: for a historical money amount, a modern-equivalent line, else null
        - sourceUrls: leave as an empty array
        - rank: 1 is most important
        Also include 0 to 3 dated real-world events as kind "event" with dateText and sortDate. \
        Finish with a 2 to 3 sentence spoiler-free briefing that orients someone entering this chapter, \
        drawn only from this text.
        """

        let user = """
        Book: "\(book.title)"\(book.authorLine.isEmpty ? "" : " by \(book.authorLine)")
        Chapter \(chapter): "\(chapterTitle)"
        Entities already introduced in earlier chapters (do not reset their first mention): \(known)

        Chapter text:
        \"\"\"
        \(text)
        \"\"\"
        """

        let raw = try await client.extract(
            system: system,
            user: user,
            schema: LocalPackBuilder.schema,
            schemaName: "chapter_entities"
        )

        struct EntityPayload: Decodable {
            let kind: String
            let name: String
            let oneLiner: String
            let detail: String?
            let wikipediaTitle: String?
            let latitude: Double?
            let longitude: Double?
            let firstMentionChapter: Int?
            let affiliation: String?
            let pronunciation: String?
            let thenNow: String?
            let sourceUrls: [String]
            let rank: Int
            let dateText: String?
            let sortDate: String?
        }
        struct PackPayload: Decodable {
            let briefing: String
            let entities: [EntityPayload]
        }

        let payload: PackPayload = try Self.decode(raw)
        let entities = payload.entities.compactMap { e -> Entity? in
            guard let kind = EntityKind(rawValue: e.kind.lowercased()) else { return nil }
            return Entity(
                kind: kind,
                name: e.name,
                oneLiner: e.oneLiner,
                detail: e.detail,
                wikipediaTitle: e.wikipediaTitle,
                imageURL: nil,
                latitude: e.latitude,
                longitude: e.longitude,
                firstMentionChapter: e.firstMentionChapter.map { min(max($0, 1), chapter) },
                affiliation: e.affiliation,
                pronunciation: e.pronunciation,
                thenNow: e.thenNow,
                sourceURLs: e.sourceUrls.compactMap(URL.init(string:)),
                rank: e.rank,
                dateText: e.dateText,
                sortDate: e.sortDate
            )
        }
        guard !entities.isEmpty else {
            throw OpenRouterError.decode("no entities extracted from the chapter text")
        }
        log(.packs, "Local pack for \(book.title) ch\(chapter): \(entities.count) entities from text")
        return ContextPack(
            asin: book.asin,
            chapter: chapter,
            chapterTitle: chapterTitle,
            packVersion: ContextPack.currentVersion,
            briefing: payload.briefing,
            entities: entities.sorted { $0.rank < $1.rank },
            builtAt: Date()
        )
    }

    private static func decode<T: Decodable>(_ raw: String) throws -> T {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !cleaned.hasPrefix("{"), let s = cleaned.firstIndex(of: "{"), let e = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[s...e])
        }
        guard let data = cleaned.data(using: .utf8) else { throw OpenRouterError.decode("empty") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static let nullableString: [String: Any] = ["type": ["string", "null"]]
    private static let nullableNumber: [String: Any] = ["type": ["number", "null"]]
    private static let nullableInteger: [String: Any] = ["type": ["integer", "null"]]

    static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["briefing", "entities"],
        "properties": [
            "briefing": ["type": "string"],
            "entities": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": [
                        "kind", "name", "oneLiner", "detail", "wikipediaTitle", "latitude", "longitude",
                        "firstMentionChapter", "affiliation", "pronunciation", "thenNow", "sourceUrls",
                        "rank", "dateText", "sortDate",
                    ],
                    "properties": [
                        "kind": ["type": "string", "enum": ["person", "place", "organization", "product", "term", "event"]],
                        "name": ["type": "string"],
                        "oneLiner": ["type": "string"],
                        "detail": nullableString,
                        "wikipediaTitle": nullableString,
                        "latitude": nullableNumber,
                        "longitude": nullableNumber,
                        "firstMentionChapter": nullableInteger,
                        "affiliation": nullableString,
                        "pronunciation": nullableString,
                        "thenNow": nullableString,
                        "sourceUrls": ["type": "array", "items": ["type": "string"]],
                        "rank": ["type": "integer"],
                        "dateText": nullableString,
                        "sortDate": nullableString,
                    ],
                ],
            ],
        ],
    ]
}
