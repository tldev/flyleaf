import SwiftUI

// The glance surface. Everything here updates on its own; the only controls
// are the footer's chapter override and per-card hover actions.
struct PanelRootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var lastInteraction = Date.distantPast

    var body: some View {
        let prefs = Prefs.shared
        let rotation = max(8, prefs.rotationSeconds)

        TimelineView(.periodic(from: .now, by: Double(rotation))) { context in
            content(now: context.date, rotation: rotation, prefs: prefs)
        }
        .id(rotation)
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(PanelSizeKey.self) { size in
            Task { @MainActor in
                PanelController.shared.setContentSize(size)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { inside in
            if inside { lastInteraction = Date() }
        }
        .preferredColorScheme(prefs.panelTheme == .auto ? nil : (prefs.panelTheme == .dark ? .dark : .light))
    }

    @ViewBuilder
    private func content(now: Date, rotation: Int, prefs: Prefs) -> some View {
        let ambientActive = isAmbient(now: now, prefs: prefs)
        VStack(spacing: 10) {
            if ambientActive, let pack = state.activePack {
                AmbientView(
                    pack: pack,
                    now: now,
                    size: prefs.panelSize,
                    highContrast: prefs.highContrast
                )
            } else {
                cardStack(now: now, rotation: rotation, prefs: prefs)
            }
            PanelFooterView(dimmed: ambientActive)
        }
        .padding(12)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: pageIndex(now: now, rotation: rotation, prefs: prefs))
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.2), value: ambientActive)
    }

    private func isAmbient(now: Date, prefs: Prefs) -> Bool {
        guard prefs.ambientEnabled, state.activePack != nil, case .ready = state.packStatus else { return false }
        let lastActivity = max(
            state.lastAdvanceAt ?? .distantPast,
            max(lastInteraction, state.position?.syncedAt ?? .distantPast)
        )
        return now.timeIntervalSince(lastActivity) > Double(prefs.ambientDelayMinutes * 60)
    }

    private func pages(prefs: Prefs) -> [[PanelCard]] {
        var cards = [PanelCard]()
        if let pack = state.activePack, let briefing = pack.briefing, !briefing.isEmpty {
            cards.append(.briefing(chapter: pack.chapter, title: pack.chapterTitle, text: briefing))
        }
        cards.append(contentsOf: state.visibleEntities().filter { $0.kind != .event }.map(PanelCard.entity))

        guard !cards.isEmpty else { return [] }
        let pageSize = prefs.panelSize == .compact ? 1 : 3
        return stride(from: 0, to: cards.count, by: pageSize).map {
            Array(cards[$0..<min($0 + pageSize, cards.count)])
        }
    }

    private func pageIndex(now: Date, rotation: Int, prefs: Prefs) -> Int {
        let count = pages(prefs: prefs).count
        guard count > 0 else { return 0 }
        return Int(now.timeIntervalSinceReferenceDate / Double(rotation)) % count
    }

    @ViewBuilder
    private func cardStack(now: Date, rotation: Int, prefs: Prefs) -> some View {
        let allPages = pages(prefs: prefs)
        if state.currentBook == nil {
            MessageCardView(
                symbol: "book.closed",
                title: "Welcome to Flyleaf",
                message: "Connect your Amazon account and Flyleaf will follow along as you read on your Kindle.",
                size: prefs.panelSize,
                highContrast: prefs.highContrast,
                actionTitle: "Get started",
                action: { WindowManager.shared.showOnboarding() }
            )
        } else {
            switch state.packStatus {
            case .building(let phase):
                BuildingCardView(phase: phase, size: prefs.panelSize, highContrast: prefs.highContrast)
            case .needsKey:
                MessageCardView(
                    symbol: "key",
                    title: "Pack builder needs an account",
                    message: "Connect your Claude account (or add an API key) once in Settings and chapters research themselves.",
                    size: prefs.panelSize,
                    highContrast: prefs.highContrast,
                    actionTitle: "Open Settings",
                    action: { WindowManager.shared.showSettings() }
                )
            case .failed(let message):
                MessageCardView(
                    symbol: "exclamationmark.triangle",
                    title: "Could not build this chapter",
                    message: message,
                    size: prefs.panelSize,
                    highContrast: prefs.highContrast,
                    actionTitle: "Try again",
                    action: {
                        if let chapter = state.currentChapter {
                            state.ensurePack(chapter: chapter, display: true)
                        }
                    }
                )
            case .none:
                MessageCardView(
                    symbol: "antenna.radiowaves.left.and.right",
                    title: waitingTitle,
                    message: waitingMessage,
                    size: prefs.panelSize,
                    highContrast: prefs.highContrast
                )
            case .ready:
                if allPages.isEmpty {
                    MessageCardView(
                        symbol: "sparkles",
                        title: "Nothing to show yet",
                        message: "Cards for this chapter are empty. Try another chapter from the footer.",
                        size: prefs.panelSize,
                        highContrast: prefs.highContrast
                    )
                } else {
                    let index = pageIndex(now: now, rotation: rotation, prefs: prefs)
                    VStack(spacing: 10) {
                        ForEach(allPages[min(index, allPages.count - 1)]) { card in
                            cardView(card, prefs: prefs)
                        }
                    }
                    .id(index)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                }
            }
        }
    }

    private var waitingTitle: String {
        switch state.connection {
        case .needsReauth: return "Amazon needs a fresh sign-in"
        case .connecting: return "Connecting to Amazon"
        default: return "Waiting for your Kindle"
        }
    }

    private var waitingMessage: String {
        switch state.connection {
        case .needsReauth: return "Your session expired. Reconnect from the Flyleaf menu bar icon."
        case .connecting: return "Checking your session and library."
        default: return "Open the book on your Kindle and turn a page while on Wi-Fi. Flyleaf follows within a minute or two."
        }
    }

    @ViewBuilder
    private func cardView(_ card: PanelCard, prefs: Prefs) -> some View {
        switch card {
        case .briefing(let chapter, let title, let text):
            BriefingCardView(
                chapter: chapter,
                chapterTitle: title,
                briefing: text,
                size: prefs.panelSize,
                highContrast: prefs.highContrast
            )
        case .entity(let entity):
            EntityCardView(
                entity: entity,
                size: prefs.panelSize,
                highContrast: prefs.highContrast,
                onReport: { state.reportEntity($0) }
            )
        }
    }
}

struct PanelSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

enum PanelCard: Identifiable {
    case briefing(chapter: Int, title: String, text: String)
    case entity(Entity)

    var id: String {
        switch self {
        case .briefing(let chapter, _, _): return "briefing:\(chapter)"
        case .entity(let entity): return entity.id
        }
    }
}

// After a few quiet minutes the panel dims into a slow slideshow of the
// chapter's imagery. Any sync or hover brings the cards back.
struct AmbientView: View {
    let pack: ContextPack
    let now: Date
    let size: PanelSize
    let highContrast: Bool

    private var visuals: [Entity] {
        pack.entities.filter { $0.imageURL != nil || ($0.kind == .place && $0.hasCoordinates) }
    }

    var body: some View {
        let items = visuals
        Group {
            if items.isEmpty {
                BriefingCardView(
                    chapter: pack.chapter,
                    chapterTitle: pack.chapterTitle,
                    briefing: pack.briefing ?? "",
                    size: size,
                    highContrast: highContrast
                )
            } else {
                let index = Int(now.timeIntervalSinceReferenceDate / 45) % items.count
                let entity = items[index]
                ZStack(alignment: .bottomLeading) {
                    AmbientVisual(entity: entity, size: size)
                    LinearGradient(
                        colors: [.black.opacity(0.6), .clear],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                    Text(entity.name)
                        .font(Theme.kickerFont)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(12)
                }
                .frame(width: Theme.cardWidth(size), height: size == .compact ? 190 : 240)
                .cardChrome(highContrast: highContrast)
                .id(index)
                .transition(.opacity)
            }
        }
        .opacity(0.82)
    }
}

private struct AmbientVisual: View {
    let entity: Entity
    let size: PanelSize

    var body: some View {
        if let url = entity.imageURL {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .underPageBackgroundColor)
                }
            }
        } else {
            EntityCardMapFill(entity: entity)
        }
    }
}

private struct EntityCardMapFill: View {
    let entity: Entity

    var body: some View {
        if let lat = entity.latitude, let lon = entity.longitude {
            PlaceMapView(name: entity.name, latitude: lat, longitude: lon, spanDegrees: 10)
                .allowsHitTesting(false)
        } else {
            Color(nsColor: .underPageBackgroundColor)
        }
    }
}
