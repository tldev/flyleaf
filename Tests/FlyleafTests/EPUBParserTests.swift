import XCTest
@testable import Flyleaf

final class EPUBParserTests: XCTestCase {
    private func makeEPUB() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("epub-src-\(UUID().uuidString)")
        let oebps = root.appendingPathComponent("OEBPS")
        let meta = root.appendingPathComponent("META-INF")
        try fm.createDirectory(at: oebps, withIntermediateDirectories: true)
        try fm.createDirectory(at: meta, withIntermediateDirectories: true)

        try "application/epub+zip".write(to: root.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: meta.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>The Test Book</dc:title>
            <dc:creator>Ada Author</dc:creator>
          </metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="c1"/>
            <itemref idref="c2"/>
          </spine>
        </package>
        """.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
          <navPoint><navLabel><text>The Beginning</text></navLabel><content src="ch1.xhtml"/></navPoint>
          <navPoint><navLabel><text>The Middle</text></navLabel><content src="ch2.xhtml"/></navPoint>
        </navMap></ncx>
        """.write(to: oebps.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

        let ch1Body = String(repeating: "Grace Hopper worked at Harvard on the Mark I computer. ", count: 40)
        try "<html><body><h1>The Beginning</h1><p>\(ch1Body)</p></body></html>"
            .write(to: oebps.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)
        let ch2Body = String(repeating: "Later she moved to Remington Rand in New York. ", count: 40)
        try "<html><body><h1>The Middle</h1><p>\(ch2Body)</p></body></html>"
            .write(to: oebps.appendingPathComponent("ch2.xhtml"), atomically: true, encoding: .utf8)

        let epub = fm.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-X", "-r", epub.path, "mimetype", "META-INF", "OEBPS"]
        zip.standardOutput = Pipe()
        try zip.run()
        zip.waitUntilExit()
        return epub
    }

    func testParsesChaptersTitlesAndPercents() throws {
        let epub = try makeEPUB()
        let book = try EPUBParser.parse(fileURL: epub)

        XCTAssertEqual(book.title, "The Test Book")
        XCTAssertEqual(book.authors, ["Ada Author"])
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters[0].title, "The Beginning")
        XCTAssertEqual(book.chapters[1].title, "The Middle")
        XCTAssertEqual(book.chapters[0].startPercent, 0, accuracy: 0.01)
        XCTAssertGreaterThan(book.chapters[1].startPercent, 40)
        XCTAssertLessThan(book.chapters[1].startPercent, 60)
        XCTAssertTrue(book.chapters[0].text.contains("Grace Hopper"))
        XCTAssertTrue(book.chapters[1].text.contains("Remington Rand"))
        XCTAssertFalse(book.chapters[0].text.contains("<"))
    }

    func testLastReadSidecarParsing() {
        let json: [String: Any] = [
            "payload": [
                "records": [
                    ["type": "kindle.lpr", "location": "190065", "annotationId": "x-PDOC-furthest-page-read"],
                ],
            ],
        ]
        let result = KindleClient.positionFromSidecarJSON(json)
        XCTAssertEqual(result?.0, 190065)
    }
}
