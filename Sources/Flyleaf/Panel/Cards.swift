import SwiftUI
import MapKit

struct EntityCardView: View {
    let entity: Entity
    let size: PanelSize
    let highContrast: Bool
    let onReport: (Entity) -> Void

    @State private var hovered = false

    var body: some View {
        Group {
            if entity.kind == .place, entity.hasCoordinates {
                placeCard
            } else {
                standardCard
            }
        }
        .frame(width: Theme.cardWidth(size))
        .cardChrome(highContrast: highContrast)
        .overlay(alignment: .topTrailing) {
            if hovered { hoverActions }
        }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entity.kind.label): \(entity.name). \(entity.oneLiner)")
    }

    private var standardCard: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                kicker
                Text(entity.name)
                    .font(Theme.nameFont(size))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let pronunciation = entity.pronunciation {
                    Text("say: \(pronunciation)")
                        .font(Theme.captionFont)
                        .foregroundStyle(.secondary)
                }
                Text(entity.oneLiner)
                    .font(Theme.bodyFont(size))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(size == .compact ? 3 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                if let thenNow = entity.thenNow {
                    Label(thenNow, systemImage: "clock.arrow.circlepath")
                        .font(Theme.captionFont)
                        .foregroundStyle(.secondary)
                }
                if entity.kind == .event, let date = entity.dateText {
                    Label(date, systemImage: "calendar")
                        .font(Theme.captionFont)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if entity.imageURL != nil {
                entityImage
            }
        }
        .padding(16)
    }

    private var placeCard: some View {
        ZStack(alignment: .bottomLeading) {
            mapView
                .frame(width: Theme.cardWidth(size), height: size == .compact ? 130 : 165)
                .allowsHitTesting(false)
            LinearGradient(
                colors: [.black.opacity(0.75), .black.opacity(0.25), .clear],
                startPoint: .bottom,
                endPoint: .top
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: entity.kind.symbolName).font(.system(size: 10, weight: .semibold))
                    Text(kickerText)
                        .font(Theme.kickerFont)
                }
                .foregroundStyle(.white.opacity(0.75))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entity.name)
                        .font(Theme.nameFont(size))
                    if let pronunciation = entity.pronunciation {
                        Text(pronunciation)
                            .font(Theme.captionFont)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .foregroundStyle(.white)
                Text(entity.oneLiner)
                    .font(Theme.bodyFont(size))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var mapView: some View {
        if let lat = entity.latitude, let lon = entity.longitude {
            let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            Map(initialPosition: .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 6)
            ))) {
                Marker(entity.name, coordinate: center)
                    .tint(.red)
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControlVisibility(.hidden)
        } else {
            Color(nsColor: .underPageBackgroundColor)
        }
    }

    private var kicker: some View {
        HStack(spacing: 6) {
            Image(systemName: entity.kind.symbolName).font(.system(size: 10, weight: .semibold))
            Text(kickerText)
                .font(Theme.kickerFont)
        }
        .foregroundStyle(.secondary)
    }

    private var kickerText: String {
        if let first = entity.firstMentionChapter {
            return "\(entity.kind.label) · first mentioned ch. \(first)"
        }
        return entity.kind.label
    }

    private var entityImage: some View {
        AsyncImage(url: entity.imageURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                placeholderGlyph
            default:
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: Theme.imageSide(size), height: Theme.imageSide(size))
        .clipShape(imageShape)
        .overlay(imageShape.stroke(.separator.opacity(0.6), lineWidth: 0.5))
    }

    private var imageShape: AnyShape {
        entity.kind == .person
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var placeholderGlyph: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: entity.kind.symbolName)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            if entity.kind == .person || entity.kind == .place || entity.pronunciation != nil {
                CardIconButton(symbol: "speaker.wave.2", help: "Say it") {
                    Speech.say(entity.pronunciation ?? entity.name)
                }
            }
            if let source = entity.sourceURLs.first {
                CardIconButton(symbol: "arrow.up.right.square", help: "Open source") {
                    NSWorkspace.shared.open(source)
                }
            }
            CardIconButton(symbol: "eye.slash", help: "Report and hide this card") {
                onReport(entity)
            }
        }
        .padding(6)
        .background(.thinMaterial, in: Capsule())
        .padding(8)
        .transition(.opacity)
    }
}

struct CardIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct BriefingCardView: View {
    let chapter: Int
    let chapterTitle: String
    let briefing: String
    let size: PanelSize
    let highContrast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chapter \(chapter)")
                .font(Theme.kickerFont)
                .foregroundStyle(.secondary)
            Text(chapterTitle)
                .font(Theme.nameFont(size))
                .lineLimit(2)
            Text(briefing)
                .font(Theme.bodyFont(size))
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: Theme.cardWidth(size), alignment: .leading)
        .cardChrome(highContrast: highContrast)
    }
}

struct MessageCardView: View {
    let symbol: String
    let title: String
    let message: String
    let size: PanelSize
    let highContrast: Bool
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold, design: .serif))
            Text(message)
                .font(Theme.detailFont(size))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: Theme.cardWidth(size), alignment: .leading)
        .cardChrome(highContrast: highContrast)
    }
}

struct BuildingCardView: View {
    let phase: String
    let size: PanelSize
    let highContrast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phase)
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(.secondary)
            }
            ShimmerView().frame(height: 14)
            ShimmerView().frame(height: 14).padding(.trailing, 60)
            ShimmerView().frame(height: 14).padding(.trailing, 120)
        }
        .padding(16)
        .frame(width: Theme.cardWidth(size), alignment: .leading)
        .cardChrome(highContrast: highContrast)
    }
}
