import Foundation

// Builds context packs in two passes: a research pass grounded with web
// search, then a formatting pass constrained by a JSON schema. Spoiler
// windowing lives in the prompts: chapter N packs draw only on the book
// through chapter N.
final class PackBuilder: @unchecked Sendable {
    private let client: AnthropicClient

    init(client: AnthropicClient) {
        self.client = client
    }

    // MARK: TOC

    func buildTOC(book: BookRef) async throws -> BookTOC {
        log(.packs, "Building TOC for \(book.title)")
        let research = try await client.complete(
            system: """
            You reconstruct tables of contents for published books using public sources only: \
            publisher pages, retailer listings, library records, Google Books previews, reviews \
            that list chapters. Never quote book text. Report chapter titles in order, the book's \
            page count if findable, and each chapter's starting page when findable.
            """,
            user: """
            Find the table of contents for "\(book.title)" by \(book.authorLine.isEmpty ? "unknown author" : book.authorLine). \
            List every chapter in reading order with any page numbers you can find, plus total page count. \
            If you cannot find the real chapter list, say so explicitly and give your best estimate of the \
            number of chapters for a book of this length and genre.
            """,
            webSearch: true,
            maxSearches: 6
        )

        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["chapters", "source"],
            "properties": [
                "chapters": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["index", "title", "startPercent"],
                        "properties": [
                            "index": ["type": "integer"],
                            "title": ["type": "string"],
                            "startPercent": ["type": "number"],
                        ],
                    ],
                ],
                "source": ["type": "string"],
            ],
        ]

        let formatted = try await completeStructured(
            system: """
            Convert research notes about a book's table of contents into JSON. Rules: \
            index starts at 1 and increments in reading order. startPercent is each chapter's \
            starting position as a percent of the whole Kindle book (0 to 100). Kindle percent \
            includes front matter, so chapter 1 usually starts between 2 and 5 percent. When page \
            numbers are known, convert pages to percent using the total page count and add about \
            3 percent front matter offset. When unknown, distribute chapters evenly between 3 and \
            97 percent. Only include real chapters and named parts, not the copyright page or index. \
            source is a short note on where the TOC came from, for example "publisher page" or "estimated".
            """,
            user: "Research notes:\n\n\(research.text)",
            schema: schema
        )

        struct TOCPayload: Decodable {
            struct Ch: Decodable {
                let index: Int
                let title: String
                let startPercent: Double
            }
            let chapters: [Ch]
            let source: String
        }

        let payload: TOCPayload = try Self.decodePayload(from: formatted)
        guard !payload.chapters.isEmpty else {
            throw AnthropicError.decode("TOC came back empty")
        }
        let chapters = payload.chapters
            .sorted { $0.index < $1.index }
            .map { TOCChapter(index: $0.index, title: $0.title, startPercent: min(max($0.startPercent, 0), 100)) }
        log(.packs, "TOC built: \(chapters.count) chapters (\(payload.source))")
        return BookTOC(chapters: chapters, source: payload.source)
    }

    // MARK: Context packs

    func buildPack(
        book: BookRef,
        chapter: Int,
        toc: BookTOC,
        previousEntityNames: [String],
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> ContextPack {
        let chapterTitle = toc.chapter(chapter)?.title ?? "Chapter \(chapter)"
        let tocText = toc.chapters
            .map { "\($0.index). \($0.title) (starts ~\(Int($0.startPercent))%)" }
            .joined(separator: "\n")
        let knownEntities = previousEntityNames.isEmpty
            ? "none recorded yet"
            : previousEntityNames.joined(separator: ", ")

        progress("Researching \(chapterTitle)")
        let research = try await client.complete(
            system: """
            You are the researcher for Flyleaf, a glanceable reading companion. A reader is partway \
            through a book; Flyleaf shows cards about the people, places, organizations, products, \
            and terms in the chapter they are reading right now, so they never reach for their phone.

            HARD RULES
            1. Spoiler window: use only what the book has covered through the target chapter. Never \
            mention, hint at, or foreshadow anything from later chapters. When describing a person or \
            event, describe them as the reader knows them at this point in the book.
            2. Ground everything with web_search. Prefer Wikipedia, publisher material, and reputable \
            press. Note the URL for each fact cluster. Do not invent biographical details.
            3. Never quote the book's text. Work from public knowledge about its subject matter, \
            reviews, summaries, and interviews.

            For the target chapter produce research notes covering 6 to 10 entities, most important \
            first. For each entity record:
            - kind: person, place, organization, product, term, or event
            - a one-line description under 140 characters, readable at arm's length
            - one or two extra sentences of detail
            - the exact English Wikipedia article title if one clearly exists, else none
            - for places: latitude and longitude
            - for people: their affiliation (company, institution, movement) for grouping
            - the chapter where this entity most likely first appears in the book (1 through the target chapter)
            - a phonetic respelling for names an English speaker would stumble on, like "jung-JOH" for Zhengzhou
            - for money amounts tied to the chapter's era: a then-and-now conversion line, like "$300 in 2004 is about $510 today"
            - source URLs
            Also record 0 to 3 dated events the chapter covers (real-world dates, not plot beats), \
            and finish with a 2 to 3 sentence spoiler-free briefing that orients the reader entering \
            this chapter.
            """,
            user: """
            Book: "\(book.title)" by \(book.authorLine.isEmpty ? "unknown author" : book.authorLine)
            Table of contents:
            \(tocText)

            Target chapter: \(chapter) ("\(chapterTitle)")
            Entities already introduced in earlier chapters: \(knownEntities)

            Produce the research notes for chapter \(chapter) now.
            """,
            webSearch: true,
            maxSearches: 8
        )

        progress("Composing cards")
        let formatted = try await completeStructured(
            system: """
            Convert research notes into JSON for a card UI. Rules: entities ordered by rank starting \
            at 1 (most important first). oneLiner stays under 140 characters, plain language, no \
            markdown. briefing is 2 to 3 sentences, spoiler free. Use null for anything unknown; never \
            invent coordinates or Wikipedia titles. wikipediaTitle is the exact article title with \
            original capitalization and no underscores. sourceUrls holds 1 to 3 full URLs per entity. \
            Events go in as kind "event" with dateText (human readable) and sortDate (YYYY-MM-DD).
            """,
            user: "Research notes:\n\n\(research.text)",
            schema: Self.packSchema
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
            let chapterTitle: String
            let briefing: String
            let entities: [EntityPayload]
        }

        let payload: PackPayload = try Self.decodePayload(from: formatted)
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
            throw AnthropicError.decode("pack came back with no usable entities")
        }

        log(.packs, "Pack built for \(book.title) ch\(chapter): \(entities.count) entities")
        return ContextPack(
            asin: book.asin,
            chapter: chapter,
            chapterTitle: payload.chapterTitle.isEmpty ? chapterTitle : payload.chapterTitle,
            packVersion: ContextPack.currentVersion,
            briefing: payload.briefing,
            entities: entities.sorted { $0.rank < $1.rank },
            builtAt: Date()
        )
    }

    // MARK: Previously On

    func recap(book: BookRef, briefings: [(chapter: Int, text: String)], through chapter: Int) async throws -> String {
        let material = briefings.map { "Chapter \($0.chapter): \($0.text)" }.joined(separator: "\n")
        let result = try await client.complete(
            system: """
            Write a "Previously On" recap for a reader returning to a book after days away. \
            Cover only material through the chapter they are on; no spoilers past it. Warm, \
            concrete, under 130 words, second person ("you left off as..."), no markdown headers.
            """,
            user: """
            Book: "\(book.title)" by \(book.authorLine)
            The reader is at chapter \(chapter).
            Chapter briefings so far:
            \(material.isEmpty ? "None cached; recap from your own knowledge of the book's opening chapters only." : material)
            """,
            maxTokens: 1000
        )
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Ask

    func ask(question: String, book: BookRef?, chapter: Int?, useWeb: Bool) async throws -> (answer: String, sources: [URL]) {
        var context = "The reader has no book connected."
        if let book {
            context = "The reader is reading \"\(book.title)\" by \(book.authorLine)."
            if let chapter {
                context += " They are at chapter \(chapter). Answer using only knowledge a reader would have through that chapter; if the honest answer requires later material, say you are keeping it spoiler free and answer what you can."
            }
        }
        let result = try await client.complete(
            system: """
            You answer one-off questions from someone in the middle of reading a book. \
            \(context) Be direct and compact: 2 to 5 sentences, no markdown, readable at a glance.
            """,
            user: question,
            webSearch: useWeb,
            maxSearches: 4,
            maxTokens: 2000
        )
        return (result.text.trimmingCharacters(in: .whitespacesAndNewlines), result.citations)
    }

    // MARK: Structured output plumbing

    // Primary path uses output_config.format. If the API rejects that shape,
    // fall back to asking for bare JSON and stripping any code fences.
    private func completeStructured(system: String, user: String, schema: [String: Any]) async throws -> String {
        do {
            let result = try await client.complete(system: system, user: user, outputSchema: schema)
            return result.text
        } catch AnthropicError.structuredOutputRejected {
            log(.anthropic, .warn, "Structured output rejected, retrying with prompt-level JSON")
            let schemaText = String(
                data: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
                encoding: .utf8
            ) ?? "{}"
            let result = try await client.complete(
                system: system + "\nRespond with a single JSON object matching this JSON Schema, and nothing else:\n" + schemaText,
                user: user
            )
            return result.text
        }
    }

    private static func decodePayload<T: Decodable>(from text: String) throws -> T {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !cleaned.hasPrefix("{"), let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }
        guard let data = cleaned.data(using: .utf8) else {
            throw AnthropicError.decode("empty structured response")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AnthropicError.decode("payload decode failed: \(error)")
        }
    }

    private static let nullableString: [String: Any] = ["anyOf": [["type": "string"], ["type": "null"]]]
    private static let nullableNumber: [String: Any] = ["anyOf": [["type": "number"], ["type": "null"]]]
    private static let nullableInteger: [String: Any] = ["anyOf": [["type": "integer"], ["type": "null"]]]

    static let packSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["chapterTitle", "briefing", "entities"],
        "properties": [
            "chapterTitle": ["type": "string"],
            "briefing": ["type": "string"],
            "entities": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": [
                        "kind", "name", "oneLiner", "detail", "wikipediaTitle",
                        "latitude", "longitude", "firstMentionChapter", "affiliation",
                        "pronunciation", "thenNow", "sourceUrls", "rank", "dateText", "sortDate",
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
