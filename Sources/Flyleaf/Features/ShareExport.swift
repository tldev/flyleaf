import Foundation

// Stand-in for the hosted share link: a self-contained HTML page of the
// book's Cast and Atlas so far, safe to send to a friend at the same point.
enum ShareExport {
    static func html(book: BookRef, packs: [ContextPack], throughChapter: Int) -> String {
        var entities = [String: Entity]()
        for pack in packs {
            for entity in pack.entities where entities[entity.id] == nil {
                entities[entity.id] = entity
            }
        }
        let people = entities.values.filter { $0.kind == .person }.sorted { $0.name < $1.name }
        let places = entities.values.filter { $0.kind == .place }.sorted { $0.name < $1.name }
        let others = entities.values
            .filter { $0.kind != .person && $0.kind != .place && $0.kind != .event }
            .sorted { $0.name < $1.name }

        func section(_ title: String, _ items: [Entity]) -> String {
            guard !items.isEmpty else { return "" }
            let rows = items.map { e -> String in
                let img = e.imageURL.map { "<img src=\"\($0.absoluteString)\" alt=\"\" />" } ?? ""
                let sources = e.sourceURLs.prefix(2)
                    .map { "<a href=\"\($0.absoluteString)\">source</a>" }
                    .joined(separator: " · ")
                let first = e.firstMentionChapter.map { "First mentioned ch. \($0)" } ?? ""
                return """
                <div class="card">\(img)<div><h3>\(escape(e.name))</h3>
                <p>\(escape(e.oneLiner))</p>
                <p class="meta">\(first) \(sources)</p></div></div>
                """
            }.joined(separator: "\n")
            return "<h2>\(title)</h2>\n<div class=\"grid\">\(rows)</div>"
        }

        return """
        <!doctype html>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(book.title)): the story so far</title>
        <style>
        body { font-family: Georgia, serif; max-width: 760px; margin: 40px auto; padding: 0 20px; color: #222; }
        h1 { font-size: 30px; margin-bottom: 4px; }
        .sub { color: #777; margin-bottom: 30px; }
        h2 { margin-top: 36px; border-bottom: 1px solid #ddd; padding-bottom: 6px; }
        .grid { display: grid; gap: 14px; }
        .card { display: flex; gap: 14px; align-items: flex-start; }
        .card img { width: 64px; height: 64px; object-fit: cover; border-radius: 10px; }
        .card h3 { margin: 0 0 4px; font-size: 18px; }
        .card p { margin: 0 0 4px; font-size: 14px; line-height: 1.45; }
        .meta { color: #999; font-size: 12px; }
        .meta a { color: #7a6a52; }
        footer { margin-top: 44px; color: #aaa; font-size: 12px; }
        </style>
        <h1>\(escape(book.title))</h1>
        <p class="sub">by \(escape(book.authorLine)) · the cast and places through chapter \(throughChapter), spoiler free</p>
        \(section("Cast", people))
        \(section("Atlas", places))
        \(section("Objects and terms", others))
        <footer>Made with Flyleaf</footer>
        """
    }

    static func writeExport(book: BookRef, packs: [ContextPack], throughChapter: Int) -> URL? {
        let content = html(book: book, packs: packs, throughChapter: throughChapter)
        let safeName = book.title.replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "", options: .regularExpression)
        let url = AppPaths.exportsDir.appendingPathComponent("\(safeName) through ch \(throughChapter).html")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            log(.app, .error, "Export failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
