import Foundation

// Local pack cache keyed by (asin, chapter, packVersion). In the shipping
// product this sits behind a shared server cache; the keying is identical so
// the server can slot in without touching callers.
final class PackStore: @unchecked Sendable {
    private let db: SQLiteDB
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(url: URL = AppPaths.databaseURL) throws {
        db = try SQLiteDB(path: url.path)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        try migrate()
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS packs (
            asin TEXT NOT NULL,
            chapter INTEGER NOT NULL,
            version INTEGER NOT NULL,
            json TEXT NOT NULL,
            built_at REAL NOT NULL,
            PRIMARY KEY (asin, chapter, version)
        );
        CREATE TABLE IF NOT EXISTS toc (
            asin TEXT PRIMARY KEY,
            json TEXT NOT NULL,
            built_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS positions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            asin TEXT NOT NULL,
            percent REAL NOT NULL,
            at REAL NOT NULL,
            source TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_positions_asin ON positions(asin, at);
        CREATE TABLE IF NOT EXISTS hidden_entities (
            asin TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            PRIMARY KEY (asin, entity_id)
        );
        CREATE TABLE IF NOT EXISTS books (
            asin TEXT PRIMARY KEY,
            json TEXT NOT NULL,
            last_seen REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS doc_meta (
            asin TEXT PRIMARY KEY,
            max_position INTEGER NOT NULL
        );
        """)
    }

    // MARK: Packs

    func savePack(_ pack: ContextPack) {
        guard let data = try? encoder.encode(pack), let json = String(data: data, encoding: .utf8) else { return }
        try? db.run(
            "INSERT OR REPLACE INTO packs (asin, chapter, version, json, built_at) VALUES (?,?,?,?,?)",
            [.text(pack.asin), .int(Int64(pack.chapter)), .int(Int64(pack.packVersion)), .text(json), .real(pack.builtAt.timeIntervalSince1970)]
        )
    }

    func loadPack(asin: String, chapter: Int, version: Int = ContextPack.currentVersion) -> ContextPack? {
        guard let rows = try? db.query(
            "SELECT json FROM packs WHERE asin=? AND chapter=? AND version=?",
            [.text(asin), .int(Int64(chapter)), .int(Int64(version))]
        ), let json = rows.first?["json"]?.stringValue,
        let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(ContextPack.self, from: data)
    }

    func hasPack(asin: String, chapter: Int, version: Int = ContextPack.currentVersion) -> Bool {
        loadPack(asin: asin, chapter: chapter, version: version) != nil
    }

    func packs(asin: String, throughChapter: Int, version: Int = ContextPack.currentVersion) -> [ContextPack] {
        guard let rows = try? db.query(
            "SELECT json FROM packs WHERE asin=? AND chapter<=? AND version=? ORDER BY chapter ASC",
            [.text(asin), .int(Int64(throughChapter)), .int(Int64(version))]
        ) else { return [] }
        return rows.compactMap { row in
            guard let json = row["json"]?.stringValue, let data = json.data(using: .utf8) else { return nil }
            return try? decoder.decode(ContextPack.self, from: data)
        }
    }

    func clearPacks() {
        try? db.run("DELETE FROM packs")
        try? db.run("DELETE FROM toc")
    }

    func clearChapter(asin: String, chapter: Int) {
        try? db.run("DELETE FROM packs WHERE asin=? AND chapter=?", [.text(asin), .int(Int64(chapter))])
    }

    // MARK: TOC

    func saveTOC(_ toc: BookTOC, asin: String) {
        guard let data = try? encoder.encode(toc), let json = String(data: data, encoding: .utf8) else { return }
        try? db.run(
            "INSERT OR REPLACE INTO toc (asin, json, built_at) VALUES (?,?,?)",
            [.text(asin), .text(json), .real(Date().timeIntervalSince1970)]
        )
    }

    func loadTOC(asin: String) -> BookTOC? {
        guard let rows = try? db.query("SELECT json FROM toc WHERE asin=?", [.text(asin)]),
              let json = rows.first?["json"]?.stringValue,
              let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(BookTOC.self, from: data)
    }

    // MARK: Positions

    func recordPosition(_ s: PositionSample) {
        try? db.run(
            "INSERT INTO positions (asin, percent, at, source) VALUES (?,?,?,?)",
            [.text(s.asin), .real(s.percent), .real(s.at.timeIntervalSince1970), .text(s.source)]
        )
    }

    func positions(asin: String, since: Date? = nil) -> [PositionSample] {
        let sinceTime = since?.timeIntervalSince1970 ?? 0
        guard let rows = try? db.query(
            "SELECT percent, at, source FROM positions WHERE asin=? AND at>=? ORDER BY at ASC",
            [.text(asin), .real(sinceTime)]
        ) else { return [] }
        return rows.compactMap { row in
            guard let percent = row["percent"]?.doubleValue,
                  let at = row["at"]?.doubleValue,
                  let source = row["source"]?.stringValue else { return nil }
            return PositionSample(asin: asin, percent: percent, at: Date(timeIntervalSince1970: at), source: source)
        }
    }

    func lastPosition(asin: String) -> PositionSample? {
        positions(asin: asin).last
    }

    // MARK: Hidden entities (report this card)

    func hideEntity(asin: String, entityID: String) {
        try? db.run(
            "INSERT OR REPLACE INTO hidden_entities (asin, entity_id) VALUES (?,?)",
            [.text(asin), .text(entityID)]
        )
    }

    func hiddenEntities(asin: String) -> Set<String> {
        guard let rows = try? db.query("SELECT entity_id FROM hidden_entities WHERE asin=?", [.text(asin)]) else { return [] }
        return Set(rows.compactMap { $0["entity_id"]?.stringValue })
    }

    // MARK: Books

    func saveBook(_ book: BookRef) {
        guard let data = try? encoder.encode(book), let json = String(data: data, encoding: .utf8) else { return }
        try? db.run(
            "INSERT OR REPLACE INTO books (asin, json, last_seen) VALUES (?,?,?)",
            [.text(book.asin), .text(json), .real(Date().timeIntervalSince1970)]
        )
    }

    func book(asin: String) -> BookRef? {
        guard let rows = try? db.query("SELECT json FROM books WHERE asin=?", [.text(asin)]),
              let json = rows.first?["json"]?.stringValue,
              let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(BookRef.self, from: data)
    }

    func books() -> [BookRef] {
        guard let rows = try? db.query("SELECT json FROM books ORDER BY last_seen DESC") else { return [] }
        return rows.compactMap { row in
            guard let json = row["json"]?.stringValue, let data = json.data(using: .utf8) else { return nil }
            return try? decoder.decode(BookRef.self, from: data)
        }
    }

    // MARK: Personal-document position scale

    func docMaxPosition(asin: String) -> Int? {
        guard let rows = try? db.query("SELECT max_position FROM doc_meta WHERE asin=?", [.text(asin)]) else { return nil }
        return rows.first?["max_position"]?.intValue.map(Int.init)
    }

    func setDocMaxPosition(asin: String, position: Int) {
        try? db.run(
            "INSERT OR REPLACE INTO doc_meta (asin, max_position) VALUES (?,?)",
            [.text(asin), .int(Int64(position))]
        )
    }
}
