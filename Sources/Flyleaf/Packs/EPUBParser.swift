import Foundation

struct ImportedChapter {
    var index: Int
    var title: String
    var text: String
    var startPercent: Double
    var charCount: Int
}

struct ImportedBook {
    var title: String
    var authors: [String]
    var chapters: [ImportedChapter]

    var toc: BookTOC {
        BookTOC(
            chapters: chapters.map { TOCChapter(index: $0.index, title: $0.title, startPercent: $0.startPercent) },
            source: "epub"
        )
    }
}

enum EPUBError: Error, CustomStringConvertible {
    case notAnEPUB
    case unzipFailed(String)
    case noContainer
    case noSpine
    case empty

    var description: String {
        switch self {
        case .notAnEPUB: return "That file is not an EPUB"
        case .unzipFailed(let m): return "Could not open the EPUB: \(m)"
        case .noContainer: return "EPUB is missing its container.xml"
        case .noSpine: return "EPUB has no readable spine"
        case .empty: return "No text found in the EPUB"
        }
    }
}

// Parses an EPUB entirely on-device: unzip, read the OPF spine and metadata,
// map the navigation TOC onto spine documents, and produce chapters with real
// text and real start percentages by cumulative length. No book ever leaves
// the Mac; nothing touches Amazon or DRM (the user supplies their own file).
enum EPUBParser {
    static func parse(fileURL: URL) throws -> ImportedBook {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("flyleaf-epub-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        try unzip(fileURL, to: temp)

        // container.xml → OPF path
        let containerURL = temp.appendingPathComponent("META-INF/container.xml")
        guard let containerXML = try? String(contentsOf: containerURL, encoding: .utf8),
              let opfRel = firstMatch(#"full-path="([^"]+)""#, in: containerXML) else {
            throw EPUBError.noContainer
        }
        let opfURL = temp.appendingPathComponent(opfRel)
        let opfDir = opfURL.deletingLastPathComponent()
        guard let opf = try? String(contentsOf: opfURL, encoding: .utf8) else {
            throw EPUBError.noContainer
        }

        let title = firstMatch(#"<dc:title[^>]*>([^<]+)</dc:title>"#, in: opf)?.xmlDecoded ?? fileURL.deletingPathExtension().lastPathComponent
        let authors = matches(#"<dc:creator[^>]*>([^<]+)</dc:creator>"#, in: opf).map { $0.xmlDecoded }

        // manifest: id -> href
        var manifest = [String: String]()
        for item in matchesFull(#"<item\s+[^>]*/?>"#, in: opf) {
            guard let id = firstMatch(#"id="([^"]+)""#, in: item),
                  let href = firstMatch(#"href="([^"]+)""#, in: item) else { continue }
            manifest[id] = href.xmlDecoded
        }
        // spine: ordered idrefs
        let spineIds = matches(#"<itemref\s+[^>]*idref="([^"]+)"[^>]*/?>"#, in: opf)
        let spineHrefs = spineIds.compactMap { manifest[$0] }
        guard !spineHrefs.isEmpty else { throw EPUBError.noSpine }

        // Navigation titles: EPUB3 nav or EPUB2 NCX, mapping a spine filename
        // to a human chapter title.
        let navTitles = readNavTitles(opf: opf, manifest: manifest, opfDir: opfDir)

        // Build a document per spine item with its plain text.
        struct Doc { let href: String; let text: String }
        var docs = [Doc]()
        for href in spineHrefs {
            let fileURL = opfDir.appendingPathComponent(href.removingPercentEncoding ?? href)
            guard let html = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let text = plainText(fromHTML: html)
            if text.count > 40 { docs.append(Doc(href: (href as NSString).lastPathComponent, text: text)) }
        }
        guard !docs.isEmpty else { throw EPUBError.empty }

        // Merge very short documents into the previous chapter, and name each
        // by the nav title when available.
        let totalChars = docs.reduce(0) { $0 + $1.text.count }
        var chapters = [ImportedChapter]()
        var cumulative = 0
        var chapterIndex = 0
        for doc in docs {
            let startPercent = totalChars > 0 ? Double(cumulative) / Double(totalChars) * 100 : 0
            let navTitle = navTitles[doc.href]
            let shouldMerge = navTitle == nil && !chapters.isEmpty && doc.text.count < 1500
            if shouldMerge {
                chapters[chapters.count - 1].text += "\n\n" + doc.text
                chapters[chapters.count - 1].charCount += doc.text.count
            } else {
                chapterIndex += 1
                chapters.append(ImportedChapter(
                    index: chapterIndex,
                    title: navTitle ?? firstHeading(doc.text) ?? "Chapter \(chapterIndex)",
                    text: doc.text,
                    startPercent: startPercent,
                    charCount: doc.text.count
                ))
            }
            cumulative += doc.text.count
        }
        // Reindex after merges.
        for i in chapters.indices { chapters[i].index = i + 1 }

        return ImportedBook(title: title.trimmingCharacters(in: .whitespacesAndNewlines), authors: authors, chapters: chapters)
    }

    // MARK: Helpers

    private static func unzip(_ file: URL, to dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-qq", file.path, "-d", dir.path]
        let err = Pipe()
        process.standardError = err
        do { try process.run() } catch { throw EPUBError.unzipFailed(error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw EPUBError.unzipFailed(msg)
        }
    }

    private static func readNavTitles(opf: String, manifest: [String: String], opfDir: URL) -> [String: String] {
        var titles = [String: String]()
        // EPUB3 nav document (properties="nav")
        if let navItem = matchesFull(#"<item\s+[^>]*properties="[^"]*nav[^"]*"[^>]*>"#, in: opf).first,
           let href = firstMatch(#"href="([^"]+)""#, in: navItem),
           let nav = try? String(contentsOf: opfDir.appendingPathComponent(href.xmlDecoded), encoding: .utf8) {
            for a in matchesFull(#"<a\s+[^>]*href="([^"]+)"[^>]*>([^<]+)</a>"#, in: nav) {
                if let href = firstMatch(#"href="([^"]+)""#, in: a),
                   let label = firstMatch(#">([^<]+)</a>"#, in: a) {
                    let file = ((href.xmlDecoded.components(separatedBy: "#").first ?? href) as NSString).lastPathComponent
                    if titles[file] == nil { titles[file] = label.xmlDecoded.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
        }
        // EPUB2 NCX fallback
        if titles.isEmpty, let ncxHref = manifest["ncx"] ?? manifest.values.first(where: { $0.hasSuffix(".ncx") }),
           let ncx = try? String(contentsOf: opfDir.appendingPathComponent(ncxHref), encoding: .utf8) {
            for point in matchesFull(#"<navPoint[^>]*>.*?</navPoint>"#, in: ncx, dotMatchesNewlines: true) {
                if let label = firstMatch(#"<text>([^<]+)</text>"#, in: point),
                   let src = firstMatch(#"src="([^"]+)""#, in: point) {
                    let file = ((src.xmlDecoded.components(separatedBy: "#").first ?? src) as NSString).lastPathComponent
                    if titles[file] == nil { titles[file] = label.xmlDecoded.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
        }
        return titles
    }

    private static func plainText(fromHTML html: String) -> String {
        var s = html
        // Drop head, scripts, styles.
        for pattern in [#"(?s)<head.*?</head>"#, #"(?s)<script.*?</script>"#, #"(?s)<style.*?</style>"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Block elements become newlines so paragraphs survive.
        s = s.replacingOccurrences(of: #"(?i)</(p|div|h[1-6]|li|br|section)>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = s.xmlDecoded
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstHeading(_ text: String) -> String? {
        let line = text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line, (2...80).contains(line.count) else { return nil }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    private static func matchesFull(_ pattern: String, in text: String, dotMatchesNewlines: Bool = false) -> [String] {
        var options: NSRegularExpression.Options = [.caseInsensitive]
        if dotMatchesNewlines { options.insert(.dotMatchesLineSeparators) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { m in
            guard let r = Range(m.range, in: text) else { return nil }
            return String(text[r])
        }
    }
}

private extension String {
    var xmlDecoded: String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#8217;", with: "\u{2019}")
            .replacingOccurrences(of: "&#8216;", with: "\u{2018}")
            .replacingOccurrences(of: "&#8220;", with: "\u{201C}")
            .replacingOccurrences(of: "&#8221;", with: "\u{201D}")
            .replacingOccurrences(of: "&#8212;", with: "\u{2014}")
            .replacingOccurrences(of: "&#8230;", with: "\u{2026}")
    }
}

