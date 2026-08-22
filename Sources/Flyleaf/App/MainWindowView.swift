import SwiftUI

enum MainTab: String, Hashable {
    case dashboard, cast, atlas, timeline, objects, stats
}

// The app's home. Dashboard carries the current chapter's cards; the other
// tabs are the accumulated Shelf.
struct MainWindowView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let packs = state.accumulatedPacks()
        TabView(selection: $state.mainTab) {
            DashboardTab()
                .tabItem { Label("Dashboard", systemImage: "rectangle.grid.2x2") }
                .tag(MainTab.dashboard)
            CastTab(packs: packs)
                .tabItem { Label("Cast", systemImage: "person.2") }
                .tag(MainTab.cast)
            AtlasTab(packs: packs)
                .tabItem { Label("Atlas", systemImage: "map") }
                .tag(MainTab.atlas)
            TimelineTab(packs: packs)
                .tabItem { Label("Timeline", systemImage: "calendar.day.timeline.left") }
                .tag(MainTab.timeline)
            ObjectsTab(packs: packs)
                .tabItem { Label("Objects", systemImage: "shippingbox") }
                .tag(MainTab.objects)
            StatsTab()
                .tabItem { Label("Stats", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(MainTab.stats)
        }
        .padding(.top, 4)
        .frame(minWidth: 780, minHeight: 560)
    }
}

struct DashboardTab: View {
    @Environment(AppState.self) private var state

    private let columns = [GridItem(.adaptive(minimum: 348, maximum: 420), spacing: 14, alignment: .top)]

    var body: some View {
        if state.currentBook == nil {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    BookHeaderView()
                    statusCard
                    cardsGrid
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "book.closed")
                .font(.system(size: 44))
                .foregroundStyle(.quaternary)
            Text("Nothing on the desk yet")
                .font(.system(size: 20, weight: .semibold, design: .serif))
            Text("Connect your Amazon account, or pick any book manually.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Connect Amazon…") { WindowManager.shared.showLogin() }
                    .buttonStyle(.borderedProminent)
                Button("Pick a book…") { WindowManager.shared.showManualPicker() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusCard: some View {
        switch state.packStatus {
        case .building(let phase):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(phase)…")
                        .font(.system(size: 14, weight: .medium, design: .serif))
                    Text("First look at a chapter takes a little while; afterwards it is instant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        case .needsKey:
            HStack(spacing: 10) {
                Image(systemName: "key").foregroundStyle(.orange)
                Text("Chapter research needs your Claude account (or an API key). Set it up once in Settings, Pack Builder.")
                    .font(.callout)
                Spacer()
                Button("Open Settings") { WindowManager.shared.showSettings() }
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .lineLimit(4)
                Spacer()
                Button("Try again") {
                    if let chapter = state.currentChapter {
                        state.ensurePack(chapter: chapter, display: true)
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        case .none:
            if state.connection == .connected {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
                    Text("Waiting for your Kindle. Open the book and turn a page while on Wi-Fi; Flyleaf follows within a minute or two.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(14)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var cardsGrid: some View {
        if let pack = state.activePack {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                if let briefing = pack.briefing, !briefing.isEmpty {
                    BriefingCardView(
                        chapter: pack.chapter,
                        chapterTitle: pack.chapterTitle,
                        briefing: briefing,
                        size: .regular,
                        highContrast: Prefs.shared.highContrast
                    )
                }
                ForEach(state.visibleEntities().filter { $0.kind != .event }) { entity in
                    EntityCardView(
                        entity: entity,
                        size: .regular,
                        highContrast: Prefs.shared.highContrast,
                        onReport: { state.reportEntity($0) }
                    )
                }
            }
        }
    }
}

// Cover, progress, sync state, and the chapter override in one header row.
struct BookHeaderView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: state.currentBook?.coverURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                        .overlay(Image(systemName: "book.closed").font(.title2).foregroundStyle(.secondary))
                }
            }
            .frame(width: 68, height: 102)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(state.currentBook?.title ?? "")
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                    .lineLimit(2)
                if let authors = state.currentBook?.authorLine, !authors.isEmpty {
                    Text(authors)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if let percent = state.position?.percent {
                        ProgressView(value: percent, total: 100)
                            .frame(width: 160)
                        Text("\(Int(percent))%")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(syncText)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    chapterStepper
                    if state.manualPin != nil {
                        Button {
                            state.manualPin = nil
                            state.recomputeChapter()
                        } label: {
                            Label("Pinned by hand", systemImage: "pin.fill")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.orange)
                        .help("Click to follow the Kindle again")
                    }
                    if state.connection == .connected {
                        Button {
                            state.poller.pollSoon()
                        } label: {
                            Label("Sync now", systemImage: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if state.connection == .needsReauth {
                        Button {
                            WindowManager.shared.showLogin()
                        } label: {
                            Label("Re-connect Amazon", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)
                    }
                    shareButton
                }
            }
            Spacer()
        }
    }

    private var syncText: String {
        if state.currentBook?.isManual == true { return "manual mode" }
        guard let position = state.position else { return "" }
        let seconds = Int(Date().timeIntervalSince(position.syncedAt))
        let when = seconds < 90 ? "just now" : seconds < 3600 ? "\(seconds / 60)m ago" : "\(seconds / 3600)h ago"
        if let device = position.deviceName, !device.isEmpty {
            return "synced \(when) from \(device)"
        }
        return "synced \(when)"
    }

    @ViewBuilder
    private var chapterStepper: some View {
        if let toc = state.toc {
            HStack(spacing: 4) {
                Button {
                    if let chapter = state.currentChapter { state.setManualChapter(chapter - 1) }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled((state.currentChapter ?? 1) <= 1)
                Menu {
                    ForEach(toc.chapters) { chapter in
                        Button {
                            state.setManualChapter(chapter.index)
                        } label: {
                            if chapter.index == state.currentChapter {
                                Label("\(chapter.index). \(chapter.title)", systemImage: "checkmark")
                            } else {
                                Text("\(chapter.index). \(chapter.title)")
                            }
                        }
                    }
                } label: {
                    Text(chapterMenuLabel)
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button {
                    state.setManualChapter((state.currentChapter ?? 0) + 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled((state.currentChapter ?? 0) >= toc.maxChapter)
            }
            .controlSize(.small)
        }
    }

    private var chapterMenuLabel: String {
        guard let toc = state.toc else { return "" }
        if let chapter = state.currentChapter, let entry = toc.chapter(chapter) {
            return "Ch \(chapter) of \(toc.maxChapter): \(entry.title)"
        }
        return "Chapter…"
    }

    private var shareButton: some View {
        Button {
            guard let book = state.currentBook, let chapter = state.currentChapter else { return }
            let packs = state.accumulatedPacks()
            if let url = ShareExport.writeExport(book: book, packs: packs, throughChapter: chapter) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } label: {
            Label("Share…", systemImage: "square.and.arrow.up")
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(state.accumulatedPacks().isEmpty)
        .help("Export the Cast and Atlas so far as a spoiler-free page")
    }
}
