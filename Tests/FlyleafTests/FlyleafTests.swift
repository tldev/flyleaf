import XCTest
@testable import Flyleaf

final class PollPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: hour, minute: minute))!
    }

    func testActiveSessionPollsFast() {
        let now = date(hour: 20)
        let interval = PollPolicy.interval(
            now: now,
            lastAdvanceAt: now.addingTimeInterval(-5 * 60),
            activeSeconds: 50,
            idleSeconds: 600,
            calendar: calendar
        )
        XCTAssertEqual(interval, 50)
    }

    func testIdleBacksOff() {
        let now = date(hour: 20)
        let interval = PollPolicy.interval(
            now: now,
            lastAdvanceAt: now.addingTimeInterval(-45 * 60),
            activeSeconds: 50,
            idleSeconds: 600,
            calendar: calendar
        )
        XCTAssertEqual(interval, 600)
    }

    func testOvernightSuspends() {
        let now = date(hour: 3)
        let interval = PollPolicy.interval(
            now: now,
            lastAdvanceAt: now.addingTimeInterval(-5 * 3600),
            activeSeconds: 50,
            idleSeconds: 600,
            calendar: calendar
        )
        XCTAssertEqual(interval, 3600)
    }

    func testOvernightReadingStaysActive() {
        let now = date(hour: 3)
        let interval = PollPolicy.interval(
            now: now,
            lastAdvanceAt: now.addingTimeInterval(-3 * 60),
            activeSeconds: 50,
            idleSeconds: 600,
            calendar: calendar
        )
        XCTAssertEqual(interval, 50)
    }

    func testNeverAdvancedIsIdle() {
        let interval = PollPolicy.interval(
            now: date(hour: 14),
            lastAdvanceAt: nil,
            activeSeconds: 50,
            idleSeconds: 600,
            calendar: calendar
        )
        XCTAssertEqual(interval, 600)
    }

    func testJitterStaysInBand() {
        let base: TimeInterval = 100
        XCTAssertEqual(PollPolicy.jittered(base, random: 0), 85, accuracy: 0.01)
        XCTAssertEqual(PollPolicy.jittered(base, random: 1), 115, accuracy: 0.01)
        XCTAssertEqual(PollPolicy.jittered(base, random: 0.5), 100, accuracy: 0.01)
    }
}

final class ChapterMapTests: XCTestCase {
    private let toc = BookTOC(
        chapters: [
            TOCChapter(index: 1, title: "One", startPercent: 3),
            TOCChapter(index: 2, title: "Two", startPercent: 20),
            TOCChapter(index: 3, title: "Three", startPercent: 55),
        ],
        source: "test"
    )

    func testMapsPercentToChapter() {
        XCTAssertEqual(toc.chapterIndex(forPercent: 0), 1)
        XCTAssertEqual(toc.chapterIndex(forPercent: 3), 1)
        XCTAssertEqual(toc.chapterIndex(forPercent: 19.9), 1)
        XCTAssertEqual(toc.chapterIndex(forPercent: 20), 2)
        XCTAssertEqual(toc.chapterIndex(forPercent: 54), 2)
        XCTAssertEqual(toc.chapterIndex(forPercent: 55), 3)
        XCTAssertEqual(toc.chapterIndex(forPercent: 100), 3)
    }

    func testBeforeFirstChapterClampsToFirst() {
        XCTAssertEqual(toc.chapterIndex(forPercent: 1), 1)
    }
}

final class ReadingStatsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ minutes: Double, _ percent: Double) -> PositionSample {
        PositionSample(asin: "X", percent: percent, at: base.addingTimeInterval(minutes * 60), source: "test")
    }

    func testSessionClustering() {
        let samples = [
            sample(0, 10), sample(2, 11), sample(5, 12), sample(8, 13),
            // 3 hour gap, new session
            sample(188, 13.5), sample(191, 15),
        ]
        let sessions = ReadingStats.sessions(from: samples)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].startPercent, 10)
        XCTAssertEqual(sessions[0].endPercent, 13)
        XCTAssertEqual(sessions[1].delta, 1.5, accuracy: 0.001)
    }

    func testNoAdvanceNoSession() {
        let samples = [sample(0, 10), sample(2, 10), sample(4, 10)]
        XCTAssertTrue(ReadingStats.sessions(from: samples).isEmpty)
    }

    func testRateComputation() {
        // 3 percent over 30 minutes = 6 percent per hour.
        let samples = [sample(0, 10), sample(10, 11), sample(20, 12), sample(30, 13)]
        let sessions = ReadingStats.sessions(from: samples)
        let rate = ReadingStats.percentPerHour(sessions)
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate!, 6.0, accuracy: 0.01)
    }

    func testStreak() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = base
        let samples = [
            PositionSample(asin: "X", percent: 10, at: now.addingTimeInterval(-2 * 86400), source: "t"),
            PositionSample(asin: "X", percent: 11, at: now.addingTimeInterval(-86400), source: "t"),
            PositionSample(asin: "X", percent: 12, at: now, source: "t"),
        ]
        XCTAssertEqual(ReadingStats.streakDays(samples: samples, calendar: calendar, now: now), 3)
    }

    func testStreakBrokenByGap() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = base
        let samples = [
            PositionSample(asin: "X", percent: 10, at: now.addingTimeInterval(-5 * 86400), source: "t"),
            PositionSample(asin: "X", percent: 12, at: now, source: "t"),
        ]
        XCTAssertEqual(ReadingStats.streakDays(samples: samples, calendar: calendar, now: now), 1)
    }
}

final class MetadataParseTests: XCTestCase {
    func testParsesJSONPWithTOC() throws {
        let jsonp = """
        loadMetadata({"asin":"B00TEST","startPosition":0,"endPosition":10000,"publisher":"Test House","releaseDate":"2025-01-01","toc":[{"title":"Chapter 1","position":100},{"title":"Chapter 2","position":4000},{"title":"Chapter 3","position":8000}]});
        """
        let meta = try KindleClient.parseMetadataJSONP(jsonp)
        XCTAssertEqual(meta.endPosition, 10000)
        XCTAssertEqual(meta.publisher, "Test House")
        XCTAssertEqual(meta.toc.count, 3)

        let toc = try XCTUnwrap(meta.bookTOC())
        XCTAssertEqual(toc.chapters.count, 3)
        XCTAssertEqual(toc.chapters[1].startPercent, 40, accuracy: 0.01)

        XCTAssertEqual(meta.percent(forPosition: 5000)!, 50, accuracy: 0.01)
    }

    func testParseRejectsGarbage() {
        XCTAssertThrowsError(try KindleClient.parseMetadataJSONP("<html>nope</html>"))
    }

    func testPercentClamped() throws {
        let meta = try KindleClient.parseMetadataJSONP("cb({\"startPosition\":0,\"endPosition\":100})")
        XCTAssertEqual(meta.percent(forPosition: 500), 100)
    }
}

final class PackStoreTests: XCTestCase {
    private func makeStore() throws -> PackStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flyleaf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try PackStore(url: dir.appendingPathComponent("test.sqlite"))
    }

    func testPackRoundTrip() throws {
        let store = try makeStore()
        let pack = DemoPack.pack()
        store.savePack(pack)

        let loaded = try XCTUnwrap(store.loadPack(asin: pack.asin, chapter: pack.chapter))
        XCTAssertEqual(loaded.entities.count, pack.entities.count)
        XCTAssertEqual(loaded.entities.first?.name, "Terry Gou")
        XCTAssertEqual(loaded.briefing, pack.briefing)
        XCTAssertEqual(loaded.entities[1].latitude!, 34.7466, accuracy: 0.0001)

        XCTAssertNil(store.loadPack(asin: pack.asin, chapter: 99))
        XCTAssertNil(store.loadPack(asin: pack.asin, chapter: pack.chapter, version: 99))
    }

    func testAccumulatedPacksRespectWindow() throws {
        let store = try makeStore()
        var pack = DemoPack.pack()
        for chapter in [1, 2, 3, 4] {
            pack.chapter = chapter
            store.savePack(pack)
        }
        XCTAssertEqual(store.packs(asin: pack.asin, throughChapter: 2).count, 2)
        XCTAssertEqual(store.packs(asin: pack.asin, throughChapter: 4).count, 4)
    }

    func testPositionsAndHidden() throws {
        let store = try makeStore()
        store.recordPosition(PositionSample(asin: "A", percent: 10, at: Date(), source: "t"))
        store.recordPosition(PositionSample(asin: "A", percent: 12, at: Date(), source: "t"))
        XCTAssertEqual(store.positions(asin: "A").count, 2)
        XCTAssertEqual(store.lastPosition(asin: "A")?.percent, 12)

        store.hideEntity(asin: "A", entityID: "person:X")
        XCTAssertTrue(store.hiddenEntities(asin: "A").contains("person:X"))
    }

    func testTOCRoundTrip() throws {
        let store = try makeStore()
        store.saveTOC(DemoPack.toc, asin: "demo")
        let loaded = try XCTUnwrap(store.loadTOC(asin: "demo"))
        XCTAssertEqual(loaded.chapters.count, DemoPack.toc.chapters.count)
        XCTAssertEqual(loaded.maxChapter, 8)
    }

    func testBookRoundTrip() throws {
        let store = try makeStore()
        store.saveBook(DemoPack.book)
        XCTAssertEqual(store.book(asin: DemoPack.book.asin)?.title, "Apple in China")
        XCTAssertEqual(store.books().count, 1)
    }
}

final class ModelTests: XCTestCase {
    func testManualBookKeying() {
        let withASIN = BookRef.manual(title: "Some Book", author: "A. Author", asin: "B0TEST123")
        XCTAssertEqual(withASIN.asin, "B0TEST123")

        let slug = BookRef.manual(title: "The Big Idea!", author: "", asin: nil)
        XCTAssertEqual(slug.asin, "manual:the-big-idea")
        XCTAssertTrue(slug.isManual)
    }

    func testLibraryAuthorNormalization() throws {
        let json = """
        {"asin":"B0X","title":"T","authors":["McGee, Patrick:"],"productUrl":null,"percentageRead":38,"resourceType":"EBOOK","originType":"PURCHASE","webReaderUrl":null}
        """
        let item = try JSONDecoder().decode(KindleLibraryItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.normalizedAuthors, ["McGee, Patrick"])
        XCTAssertEqual(item.bookRef.coverURL, nil)
        XCTAssertEqual(item.percentageRead, 38)
    }
}
