import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    let store: PackStore
    let wiki = WikipediaResolver()
    var poller: PositionPoller!
    var kindle: KindleClient?

    var connection: ConnectionState = .notConnected
    var statusMessage: String?

    var library: [BookRef] = []
    var currentBook: BookRef?
    var position: ReadingPosition?
    var toc: BookTOC?
    var manualPin: ManualPin?
    var currentChapter: Int?

    var activePack: ContextPack?
    var packStatus: PackStatus = .none
    private var buildingKeys: Set<String> = []

    var mainTab: MainTab = .dashboard
    var lastAdvanceAt: Date?
    var lastPollAt: Date?
    var hiddenEntityIDs: Set<String> = []
    var statsSummary: ReadingStats.Summary?
    var isDemo = false
    private var lastNotifiedChapter: Int?

    init() {
        do {
            store = try PackStore()
        } catch {
            fatalError("Could not open Flyleaf database: \(error)")
        }
        poller = PositionPoller(state: self)
    }

    enum BuilderAuthStatus: Equatable {
        case none, claudeAccount, apiKey
    }

    var builderAuth: BuilderAuthStatus = .none
    var builderAvailable: Bool { builderAuth != .none }

    func refreshBuilderAuth() async {
        let cliWorks = await Task.detached(operation: { AntCLI.mintAccessToken() != nil }).value
        if cliWorks {
            builderAuth = .claudeAccount
        } else if let key = Keychain.get(account: SecretAccount.anthropicKey), !key.isEmpty {
            builderAuth = .apiKey
        } else {
            builderAuth = .none
        }
        log(.anthropic, "Builder auth: \(builderAuth)")
    }

    // MARK: Lifecycle

    func bootstrap(demo: Bool) {
        Task { await refreshBuilderAuth() }
        if demo {
            loadDemo()
            return
        }
        guard Prefs.shared.onboardingComplete else { return }
        restoreLastBook()
        if Prefs.shared.amazonConnected {
            connectKindle()
        }
    }

    private func restoreLastBook() {
        guard let asin = Prefs.shared.currentASIN, let book = store.book(asin: asin) else { return }
        currentBook = book
        toc = store.loadTOC(asin: asin)
        hiddenEntityIDs = store.hiddenEntities(asin: asin)
        if let last = store.lastPosition(asin: asin) {
            position = ReadingPosition(percent: last.percent, syncedAt: last.at, deviceName: nil, kindlePosition: nil)
        }
        recomputeChapter()
        if let chapter = currentChapter, let pack = store.loadPack(asin: asin, chapter: chapter) {
            activePack = pack
            packStatus = .ready
        }
        updateStats()
    }

    func connectKindle() {
        let client = KindleClient(region: Prefs.shared.region)
        kindle = client
        connection = .connecting
        Task {
            for attempt in 1...2 {
                do {
                    let count = try await client.verifySession()
                    connection = .connected
                    statusMessage = nil
                    Prefs.shared.amazonConnected = true
                    log(.app, "Amazon session verified, \(count) books visible")
                    poller.pollSoon()
                    return
                } catch let error as KindleError where error.isAuthFailure {
                    if attempt == 1 {
                        log(.auth, .warn, "Session verify attempt 1 failed (\(error)), retrying")
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        continue
                    }
                    connection = .needsReauth
                    log(.auth, .warn, "Session verify failed: \(error)")
                } catch {
                    connection = .needsReauth
                    statusMessage = "\(error)"
                    log(.auth, .error, "Session verify error: \(error)")
                }
            }
        }
    }

    func disconnectAmazon() {
        poller.stop()
        kindle = nil
        connection = .notConnected
        Prefs.shared.amazonConnected = false
        Task { await AmazonCookies.clear() }
        log(.auth, "Signed out of Amazon")
    }

    // MARK: Polling

    func pollOnce() async {
        guard connection == .connected, let kindle, !Prefs.shared.paused else { return }
        guard currentBook?.isManual != true else { return }
        do {
            let items = try await kindle.library()
            lastPollAt = Date()
            statusMessage = nil

            let refs = items.map(\.bookRef)
            library = refs
            for ref in refs.prefix(20) { store.saveBook(ref) }

            if let first = items.first {
                let shouldAdopt = currentBook == nil
                    || (Prefs.shared.followMostRecent && first.asin != currentBook?.asin && !(currentBook?.isManual ?? false))
                if shouldAdopt && first.asin != currentBook?.asin {
                    adopt(book: first.bookRef, percent: first.percentageRead)
                    log(.poller, "Following most recent book: \(first.title)")
                }
            }

            if let book = currentBook, !book.isManual {
                // startReading's lastPageReadData is the authoritative
                // cross-device Whispersync position; the library listing's
                // percentageRead can lag it, so it is only the fallback.
                let refined = await refreshWhispersync(for: book)
                if !refined, let item = items.first(where: { $0.asin == book.asin }) {
                    apply(percent: item.percentageRead, for: book)
                }
            }
        } catch let error as KindleError where error.isAuthFailure {
            connection = .needsReauth
            log(.auth, .warn, "Poll hit auth failure: \(error)")
        } catch {
            statusMessage = "Sync problem: \(error)"
            log(.poller, .warn, "Poll failed: \(error)")
        }
    }

    private func apply(percent: Double?, for book: BookRef) {
        guard let percent, percent >= 0 else { return }
        let previous = position?.percent
        if previous == nil || abs(percent - (previous ?? -1)) > 0.001 {
            position = ReadingPosition(
                percent: percent,
                syncedAt: Date(),
                deviceName: position?.deviceName,
                kindlePosition: position?.kindlePosition
            )
            store.recordPosition(PositionSample(asin: book.asin, percent: percent, at: Date(), source: "whispersync"))
            if let previous, percent > previous {
                lastAdvanceAt = Date()
            } else if previous == nil {
                lastAdvanceAt = Date()
            }
            log(.poller, "Position for \(book.title): \(String(format: "%.1f", percent))%")
            recomputeChapter()
            updateStats()
        }
    }

    private func adopt(book: BookRef, percent: Double?) {
        currentBook = book
        Prefs.shared.currentASIN = book.asin
        store.saveBook(book)
        manualPin = nil
        activePack = nil
        packStatus = .none
        lastNotifiedChapter = nil
        hiddenEntityIDs = store.hiddenEntities(asin: book.asin)
        toc = store.loadTOC(asin: book.asin)
        position = nil
        apply(percent: percent, for: book)
        if toc == nil {
            ensureTOC(for: book)
        } else {
            recomputeChapter()
        }
    }

    func switchTo(book: BookRef) {
        adopt(book: book, percent: store.lastPosition(asin: book.asin)?.percent)
        if !book.isManual {
            poller.pollSoon()
        }
    }

    private var metadataCache = [String: BookMetadata]()

    // Reads the authoritative Whispersync position (startReading's
    // lastPageReadData) and, first time per book, delivery metadata: exact
    // position bounds plus the nav TOC when the book exposes one. Returns
    // true when a position percent was applied.
    private func refreshWhispersync(for book: BookRef) async -> Bool {
        guard !book.isManual, let kindle else { return false }
        do {
            let info = try await kindle.startReading(asin: book.asin)
            if metadataCache[book.asin] == nil, let metaURL = info.metadataUrl {
                if let meta = try? await kindle.metadata(from: metaURL) {
                    metadataCache[book.asin] = meta
                    if let exactTOC = meta.bookTOC(), toc?.source != "kindle-metadata" {
                        toc = exactTOC
                        store.saveTOC(exactTOC, asin: book.asin)
                        log(.kindle, "Using exact TOC from book metadata (\(exactTOC.chapters.count) chapters)")
                        recomputeChapter()
                    }
                }
            }
            guard let lastPage = info.lastPageReadData else { return false }
            if let device = lastPage.deviceName, !device.isEmpty {
                position?.deviceName = device
            }
            position?.kindlePosition = lastPage.position
            if let pos = lastPage.position,
               let percent = metadataCache[book.asin]?.percent(forPosition: pos) {
                let device = lastPage.deviceName
                apply(percent: percent, for: book)
                if let device, !device.isEmpty {
                    position?.deviceName = device
                }
                return true
            }
            return false
        } catch {
            log(.kindle, .debug, "Whispersync detail failed for \(book.title): \(error)")
            return false
        }
    }

    // MARK: TOC

    func ensureTOC(for book: BookRef) {
        if let cached = store.loadTOC(asin: book.asin) {
            toc = cached
            recomputeChapter()
            return
        }
        guard builderAvailable else {
            let generic = Self.genericTOC()
            toc = generic
            packStatus = .needsKey
            recomputeChapter()
            return
        }
        packStatus = .building("Finding the chapters")
        Task {
            do {
                guard let client = await AnthropicClient.resolve() else {
                    packStatus = .needsKey
                    return
                }
                let builder = PackBuilder(client: client)
                let built = try await builder.buildTOC(book: book)
                store.saveTOC(built, asin: book.asin)
                if currentBook?.asin == book.asin {
                    toc = built
                    recomputeChapter()
                    if let chapter = currentChapter {
                        ensurePack(chapter: chapter, display: true)
                    }
                }
            } catch {
                log(.packs, .error, "TOC build failed: \(error)")
                if currentBook?.asin == book.asin {
                    toc = Self.genericTOC()
                    packStatus = .failed("Could not find the table of contents. \(error)")
                    recomputeChapter()
                }
            }
        }
    }

    static func genericTOC(count: Int = 12) -> BookTOC {
        let chapters = (1...count).map { i in
            TOCChapter(
                index: i,
                title: "Chapter \(i)",
                startPercent: 3 + Double(i - 1) * (94.0 / Double(count))
            )
        }
        return BookTOC(chapters: chapters, source: "generic")
    }

    // Called when builder auth changes (key saved, CLI login): rebuild
    // whatever was skipped for lack of it.
    func builderKeyAdded() {
        Task {
            await refreshBuilderAuth()
            guard builderAvailable, let book = currentBook else { return }
            if store.loadTOC(asin: book.asin) == nil {
                ensureTOC(for: book)
            } else if let chapter = currentChapter {
                ensurePack(chapter: chapter, display: true)
            }
        }
    }

    // MARK: Chapter mapping

    func recomputeChapter() {
        guard let toc, let percent = position?.percent else {
            if manualPin == nil { currentChapter = nil }
            return
        }
        let computed = toc.chapterIndex(forPercent: percent)
        var target = computed
        if let pin = manualPin {
            let computedAtPin = toc.chapterIndex(forPercent: pin.percentAtPin)
            if computedAtPin == computed {
                target = pin.chapter
            } else {
                manualPin = nil
            }
        }
        setChapter(target)
    }

    private func setChapter(_ chapter: Int?) {
        guard chapter != currentChapter else { return }
        let old = currentChapter
        currentChapter = chapter
        log(.app, "Chapter: \(old.map(String.init) ?? "none") -> \(chapter.map(String.init) ?? "none")")
        guard let chapter else { return }
        activePack = nil
        ensurePack(chapter: chapter, display: true)
        prefetchNext(after: chapter)
    }

    func setManualChapter(_ chapter: Int) {
        guard let toc else { return }
        let clamped = min(max(chapter, 1), toc.maxChapter)
        let anchor: Double
        if let percent = position?.percent, currentBook?.isManual != true {
            anchor = percent
        } else {
            anchor = toc.chapter(clamped)?.startPercent ?? 0
            if let book = currentBook {
                position = ReadingPosition(percent: anchor, syncedAt: Date(), deviceName: "Manual", kindlePosition: nil)
                store.recordPosition(PositionSample(asin: book.asin, percent: anchor, at: Date(), source: "manual"))
            }
        }
        manualPin = ManualPin(chapter: clamped, percentAtPin: anchor)
        setChapter(clamped)
        updateStats()
    }

    // MARK: Packs

    func ensurePack(chapter: Int, display: Bool) {
        guard let book = currentBook else { return }
        if let cached = store.loadPack(asin: book.asin, chapter: chapter) {
            if display && chapter == currentChapter {
                activePack = cached
                packStatus = .ready
                notifyChapterIfNeeded(pack: cached)
            }
            return
        }
        guard builderAvailable else {
            if display { packStatus = .needsKey }
            return
        }
        guard let toc else { return }
        let key = "\(book.asin):\(chapter)"
        guard !buildingKeys.contains(key) else { return }
        buildingKeys.insert(key)
        if display {
            packStatus = .building("Researching the chapter")
        }

        let previousNames = store.packs(asin: book.asin, throughChapter: max(chapter - 1, 0))
            .flatMap { $0.entities.map(\.name) }
        let uniqueNames = Array(Set(previousNames)).sorted().prefix(40).map { String($0) }

        Task {
            defer { buildingKeys.remove(key) }
            do {
                guard let client = await AnthropicClient.resolve() else {
                    if display && currentChapter == chapter { packStatus = .needsKey }
                    return
                }
                let builder = PackBuilder(client: client)
                let raw = try await builder.buildPack(
                    book: book,
                    chapter: chapter,
                    toc: toc,
                    previousEntityNames: Array(uniqueNames),
                    progress: { phase in
                        Task { @MainActor [weak self] in
                            guard let self, display, self.currentChapter == chapter else { return }
                            self.packStatus = .building(phase)
                        }
                    }
                )
                if display && currentChapter == chapter {
                    packStatus = .building("Finding imagery")
                }
                let enriched = await wiki.enrich(raw)
                store.savePack(enriched)
                if currentChapter == chapter && currentBook?.asin == book.asin {
                    activePack = enriched
                    packStatus = .ready
                    notifyChapterIfNeeded(pack: enriched)
                }
            } catch {
                log(.packs, .error, "Pack build failed for ch\(chapter): \(error)")
                if display && currentChapter == chapter {
                    if case AnthropicError.noAuth = error {
                        packStatus = .needsKey
                    } else {
                        packStatus = .failed("\(error)")
                    }
                }
            }
        }
    }

    private func prefetchNext(after chapter: Int) {
        guard Prefs.shared.prefetchNext, let toc, chapter + 1 <= toc.maxChapter else { return }
        guard let book = currentBook, !store.hasPack(asin: book.asin, chapter: chapter + 1) else { return }
        ensurePack(chapter: chapter + 1, display: false)
    }

    private func notifyChapterIfNeeded(pack: ContextPack) {
        guard Prefs.shared.notificationsEnabled,
              lastNotifiedChapter != pack.chapter,
              let briefing = pack.briefing, !briefing.isEmpty else { return }
        if lastNotifiedChapter == nil {
            // Skip the notification for whatever chapter the app launches into.
            lastNotifiedChapter = pack.chapter
            return
        }
        lastNotifiedChapter = pack.chapter
        AppNotifications.sendChapterBriefing(chapter: pack.chapter, title: pack.chapterTitle, briefing: briefing)
    }

    // MARK: Entity actions

    func visibleEntities() -> [Entity] {
        guard let pack = activePack else { return [] }
        return pack.entities
            .filter { !hiddenEntityIDs.contains($0.id) }
            .sorted { $0.rank < $1.rank }
    }

    func reportEntity(_ entity: Entity) {
        guard let book = currentBook else { return }
        store.hideEntity(asin: book.asin, entityID: entity.id)
        hiddenEntityIDs.insert(entity.id)
        log(.packs, "Entity reported and hidden: \(entity.name)")
    }

    // MARK: Shelf data

    func accumulatedPacks() -> [ContextPack] {
        guard let book = currentBook, let chapter = currentChapter else { return [] }
        return store.packs(asin: book.asin, throughChapter: chapter)
    }

    // MARK: Manual mode

    func startManualBook(title: String, author: String, asin: String?) {
        let book = BookRef.manual(title: title, author: author, asin: asin)
        store.saveBook(book)
        adopt(book: book, percent: nil)
        setManualChapter(1)
        log(.app, "Manual mode: \(book.title) (\(book.asin))")
    }

    // MARK: Stats

    func updateStats() {
        guard let book = currentBook else {
            statsSummary = nil
            return
        }
        let samples = store.positions(asin: book.asin)
        statsSummary = ReadingStats.summary(samples: samples, currentPercent: position?.percent)
    }

    // MARK: Demo

    func loadDemo() {
        isDemo = true
        let book = DemoPack.book
        store.saveBook(book)
        currentBook = book
        Prefs.shared.currentASIN = book.asin
        toc = DemoPack.toc
        store.saveTOC(DemoPack.toc, asin: book.asin)
        position = ReadingPosition(percent: 27, syncedAt: Date(), deviceName: "Demo", kindlePosition: nil)
        store.recordPosition(PositionSample(asin: book.asin, percent: 27, at: Date(), source: "demo"))
        currentChapter = 3
        let pack = DemoPack.pack()
        activePack = pack
        packStatus = .ready
        store.savePack(pack)
        updateStats()
        log(.app, "Demo mode loaded")
        Task {
            let enriched = await wiki.enrich(pack)
            if currentBook?.asin == book.asin {
                activePack = enriched
                store.savePack(enriched)
            }
        }
    }
}
