import SwiftUI

enum MainTab: String, Hashable {
    case dashboard, cast, atlas, timeline, objects, stats
}

extension MainTab {
    var label: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .cast: return "Cast"
        case .atlas: return "Atlas"
        case .timeline: return "Timeline"
        case .objects: return "Objects"
        case .stats: return "Stats"
        }
    }
    static let order: [MainTab] = [.dashboard, .cast, .atlas, .timeline, .objects, .stats]
}

// The app's home: one warm chrome bar (wordmark, book, tabs, progress) over a
// paper surface, matching the Glance Gallery reimagining. Dashboard carries
// the current chapter's gallery; the other tabs are the accumulated Shelf.
struct MainWindowView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let packs = state.accumulatedPacks()
        VStack(spacing: 0) {
            GalleryTopBar()
            Rectangle().fill(Gallery.divider).frame(height: 1)
            Group {
                switch state.mainTab {
                case .dashboard: DashboardTab()
                case .cast: CastTab(packs: packs)
                case .atlas: AtlasTab(packs: packs)
                case .timeline: TimelineTab(packs: packs)
                case .objects: ObjectsTab(packs: packs)
                case .stats: StatsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Gallery.paper)
        .frame(minWidth: 960, minHeight: 640)
    }
}

// The unified editorial top bar: FLYLEAF, the book and current chapter, the
// section tabs with an orange active underline, and reading progress.
struct GalleryTopBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Text("FLYLEAF")
                .font(Gallery.mono(12, .semibold)).tracking(2.6)
                .foregroundStyle(Gallery.wordmark)
            contextLine
            Spacer(minLength: 16)
            tabs
            progress
        }
        .padding(.leading, 84)   // clear the window's traffic lights
        .padding(.trailing, 22)
        .padding(.top, 10).padding(.bottom, 11)
        .background(Gallery.paper)
    }

    @ViewBuilder
    private var contextLine: some View {
        if let book = state.currentBook {
            HStack(spacing: 8) {
                Text(book.title).font(Gallery.sans(13, .semibold)).foregroundStyle(Gallery.ink)
                if let chapter = state.currentChapter, let entry = state.toc?.chapter(chapter) {
                    Text("·").foregroundStyle(Gallery.muted)
                    Text("“\(entry.title)”").font(Gallery.serifItalic(14)).foregroundStyle(Gallery.inkSoft).lineLimit(1)
                    Text("·").foregroundStyle(Gallery.muted)
                    Text("Ch \(chapter) of \(state.toc?.maxChapter ?? chapter)")
                        .font(Gallery.sans(12.5)).foregroundStyle(Gallery.muted)
                }
            }
            .lineLimit(1)
        }
    }

    private var tabs: some View {
        HStack(spacing: 20) {
            ForEach(MainTab.order, id: \.self) { tab in
                let active = state.mainTab == tab
                Button { state.mainTab = tab } label: {
                    Text(tab.label)
                        .font(Gallery.sans(12.5, active ? .semibold : .regular))
                        .foregroundStyle(active ? Gallery.ink : Gallery.muted)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Gallery.accent)
                                .frame(height: 2)
                                .opacity(active ? 1 : 0)
                                .offset(y: 6)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        if let percent = state.position?.percent {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Gallery.divider).frame(width: 72, height: 4)
                    Capsule().fill(Gallery.accent).frame(width: 72 * CGFloat(min(percent, 100) / 100), height: 4)
                }
                Text("\(Int(percent))%").font(Gallery.mono(11, .medium)).foregroundStyle(Gallery.muted)
            }
            .padding(.leading, 4)
        }
    }
}

// The "Glance Gallery" Dashboard: a warm-paper editorial mosaic of the
// current chapter's cast, places, and objects. Ported from the Claude Design
// reimagining, with Apple Maps standing in for the web map.
struct DashboardTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.currentBook == nil {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    DashboardControls()
                    briefingBand
                    statusBand
                    gallery.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Gallery.paper)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "book.closed")
                .font(.system(size: 44))
                .foregroundStyle(Gallery.muted.opacity(0.6))
            Text("Nothing on the desk yet")
                .font(Gallery.serif(22))
                .foregroundStyle(Gallery.ink)
            Text("Connect your Amazon account, or pick any book manually.")
                .font(Gallery.sans(14))
                .foregroundStyle(Gallery.inkSoft)
            HStack(spacing: 12) {
                Button("Connect Amazon…") { WindowManager.shared.showLogin() }
                    .buttonStyle(.borderedProminent).tint(Gallery.accent)
                Button("Pick a book…") { WindowManager.shared.showManualPicker() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var briefingBand: some View {
        if case .ready = state.packStatus,
           let pack = state.activePack, let briefing = pack.briefing, !briefing.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Kicker(text: "Chapter \(pack.chapter) · \(pack.chapterTitle)", color: Gallery.accent)
                Text(briefing)
                    .font(Gallery.serif(14.5, .regular))
                    .foregroundStyle(Gallery.ink)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.vertical, 13)
            .background(Gallery.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Gallery.border))
        }
    }

    @ViewBuilder
    private var statusBand: some View {
        switch state.packStatus {
        case .building(let phase):
            band {
                ProgressView().controlSize(.small).tint(Gallery.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(phase)…").font(Gallery.serif(14, .medium)).foregroundStyle(Gallery.ink)
                    Text("First look at a chapter takes a little while; afterwards it is instant.")
                        .font(Gallery.sans(12)).foregroundStyle(Gallery.inkSoft)
                }
                Spacer()
            }
        case .needsKey:
            band {
                Image(systemName: "key").foregroundStyle(Gallery.accent)
                Text("Chapter research needs your Claude account (or an API key). Set it up once in Settings, Pack Builder.")
                    .font(Gallery.sans(13)).foregroundStyle(Gallery.ink)
                Spacer()
                Button("Open Settings") { WindowManager.shared.showSettings() }.tint(Gallery.accent)
            }
        case .failed(let message):
            band {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Gallery.accent)
                Text(message).font(Gallery.sans(13)).foregroundStyle(Gallery.ink).lineLimit(4)
                Spacer()
                Button("Try again") {
                    if let chapter = state.currentChapter { state.ensurePack(chapter: chapter, display: true) }
                }.tint(Gallery.accent)
            }
        case .none:
            if state.connection == .connected {
                band {
                    Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(Gallery.muted)
                    Text("Waiting for your Kindle. Open the book and turn a page while on Wi-Fi; Flyleaf follows within a minute or two.")
                        .font(Gallery.sans(13)).foregroundStyle(Gallery.inkSoft)
                    Spacer()
                }
            }
        case .ready:
            EmptyView()
        }
    }

    private func band<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Gallery.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Gallery.border))
    }

    // The gallery fills the remaining window height with no scrolling: rows
    // share the available height in proportion to their natural weight (people
    // rows taller), so everything fits like the design.
    @ViewBuilder
    private var gallery: some View {
        if case .ready = state.packStatus, state.activePack != nil {
            let entities = state.visibleEntities()
            let rows = GalleryLayout.rows(GalleryLayout.tiles(from: entities))
            let places = entities.filter { $0.kind == .place && $0.hasCoordinates }
            let weights = rows.map { GalleryLayout.rowHeight($0) }
            let totalWeight = max(1, weights.reduce(0, +))
            let gap: CGFloat = 14
            GeometryReader { geo in
                let avail = geo.size.height - gap * CGFloat(max(0, rows.count - 1))
                VStack(spacing: gap) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                        GalleryRow(
                            row: row,
                            places: places,
                            height: max(120, avail * weights[idx] / totalWeight)
                        ) { state.reportEntity($0) }
                    }
                }
            }
        }
    }
}

// A 6-column grid row at an explicit height: each tile spans its columns,
// tiles left-aligned with trailing space as a gap.
private struct GalleryRow: View {
    let row: [GalleryTile]
    let places: [Entity]
    let height: CGFloat
    let onReport: (Entity) -> Void
    private let gap: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let col = (geo.size.width - gap * CGFloat(GalleryLayout.columns - 1)) / CGFloat(GalleryLayout.columns)
            HStack(spacing: gap) {
                ForEach(row) { tile in
                    let s = CGFloat(min(tile.span, GalleryLayout.columns))
                    GalleryTileView(tile: tile, allPlaces: places, onReport: onReport)
                        .frame(width: max(0, col * s + gap * (s - 1)), height: geo.size.height)
                        .clipped()
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
    }
}

// The Dashboard's slim reading-controls row: chapter override, sync, share,
// and the sync status. Book, chapter, and progress live in the top bar.
struct DashboardControls: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            chapterStepper
            if state.manualPin != nil {
                Button {
                    state.manualPin = nil
                    state.recomputeChapter()
                } label: { Label("Pinned", systemImage: "pin.fill").font(Gallery.sans(11)) }
                .buttonStyle(.bordered).controlSize(.small).tint(Gallery.accent)
                .help("Following by hand. Click to follow the Kindle again.")
            }
            if state.connection == .connected {
                Button { state.poller.pollSoon() } label: {
                    Label("Sync now", systemImage: "arrow.clockwise").font(Gallery.sans(11))
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            if state.connection == .needsReauth {
                Button { WindowManager.shared.showLogin() } label: {
                    Label("Re-connect Amazon", systemImage: "exclamationmark.triangle.fill").font(Gallery.sans(11))
                }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(Gallery.accent)
            }
            Text(syncText).font(Gallery.sans(11)).foregroundStyle(Gallery.muted)
            Spacer()
            shareButton
        }
    }

    private var syncText: String {
        if state.currentBook?.isPersonalDoc == true, let p = state.position {
            let secs = Int(Date().timeIntervalSince(p.syncedAt))
            return secs < 90 ? "synced just now from Kindle" : "synced \(secs / 60)m ago from Kindle"
        }
        if state.currentBook?.isManual == true { return "manual mode" }
        guard let position = state.position else { return "" }
        let seconds = Int(Date().timeIntervalSince(position.syncedAt))
        let when = seconds < 90 ? "just now" : seconds < 3600 ? "\(seconds / 60)m ago" : "\(seconds / 3600)h ago"
        if let device = position.deviceName, !device.isEmpty { return "synced \(when) from \(device)" }
        return "synced \(when)"
    }

    @ViewBuilder
    private var chapterStepper: some View {
        if let toc = state.toc {
            HStack(spacing: 4) {
                Button { if let c = state.currentChapter { state.setManualChapter(c - 1) } } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled((state.currentChapter ?? 1) <= 1)
                Menu {
                    ForEach(toc.chapters) { chapter in
                        Button { state.setManualChapter(chapter.index) } label: {
                            if chapter.index == state.currentChapter {
                                Label("\(chapter.index). \(chapter.title)", systemImage: "checkmark")
                            } else {
                                Text("\(chapter.index). \(chapter.title)")
                            }
                        }
                    }
                } label: {
                    Text("I'm actually at…").font(Gallery.sans(12, .medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button { state.setManualChapter((state.currentChapter ?? 0) + 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled((state.currentChapter ?? 0) >= toc.maxChapter)
            }
            .controlSize(.small)
        }
    }

    private var shareButton: some View {
        Button {
            guard let book = state.currentBook, let chapter = state.currentChapter else { return }
            let packs = state.accumulatedPacks()
            if let url = ShareExport.writeExport(book: book, packs: packs, throughChapter: chapter) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } label: {
            Label("Share…", systemImage: "square.and.arrow.up").font(Gallery.sans(11))
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(state.accumulatedPacks().isEmpty)
        .help("Export the Cast and Atlas so far as a spoiler-free page")
    }
}
