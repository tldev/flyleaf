import SwiftUI
import MapKit

// One dispatcher that renders each gallery tile by kind, plus a shared
// context menu so every card keeps Flyleaf's actions (say it, open source,
// report). Photo-forward tiles fill their frame; textual ones sit on paper.
struct GalleryTileView: View {
    let tile: GalleryTile
    var allPlaces: [Entity] = []
    var showPronunciations: Bool = true
    let onReport: (Entity) -> Void

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Gallery.border, lineWidth: borderWidth)
            )
            .contextMenu { menu }
    }

    private var borderWidth: CGFloat {
        (tile.kind == .person || tile.kind == .placeMap) ? 0 : 1
    }

    @ViewBuilder
    private var content: some View {
        switch tile.kind {
        case .person: PersonTile(entity: tile.entity, showSay: showPronunciations)
        case .placeMap: PlaceMapTile(place: tile.entity, allPlaces: allPlaces)
        case .place: PlaceTile(entity: tile.entity)
        case .product: ProductTile(entity: tile.entity)
        case .org: OrgTile(entity: tile.entity)
        case .term: TermTile(entity: tile.entity)
        case .event: EventTile(entity: tile.entity)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if let p = tile.entity.pronunciation, !p.isEmpty {
            Button { Speech.say(p) } label: { Label("Say “\(tile.entity.name)”", systemImage: "speaker.wave.2") }
        } else {
            Button { Speech.say(tile.entity.name) } label: { Label("Say “\(tile.entity.name)”", systemImage: "speaker.wave.2") }
        }
        ForEach(tile.entity.sourceURLs.prefix(3), id: \.absoluteString) { url in
            Button { NSWorkspace.shared.open(url) } label: { Label("Open \(url.host ?? "source")", systemImage: "arrow.up.right.square") }
        }
        Divider()
        Button(role: .destructive) { onReport(tile.entity) } label: { Label("Report and hide", systemImage: "eye.slash") }
    }
}

// MARK: People (full-bleed portrait, gradient nameplate)

struct PersonTile: View {
    let entity: Entity
    let showSay: Bool

    var body: some View {
        ZStack {
            Gallery.tileFill
            Text(initials)
                .font(Gallery.serif(64, .semibold))
                .foregroundStyle(Gallery.muted.opacity(0.7))
            // Full-bleed portrait. Held inside a flexible Color so the image's
            // intrinsic size never inflates the ZStack past the tile frame
            // (which would push the name/badge overlays out of view).
            Color.clear.overlay {
                AsyncImage(url: entity.imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
            .clipped()
            LinearGradient(
                colors: [Gallery.badgeInk.opacity(0.92), Gallery.badgeInk.opacity(0.4), .clear],
                startPoint: .bottom, endPoint: .center
            )
            // Role badge, pinned top-left.
            roleBadge
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(13)
            // Nameplate, pinned bottom-left.
            VStack(alignment: .leading, spacing: 6) {
                Text(entity.name)
                    .font(Gallery.serif(29, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if showSay, let say = entity.pronunciation, !say.isEmpty {
                    Button { Speech.say(say) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.wave.2").font(.system(size: 9))
                            Text("SAY · \(say)").font(Gallery.mono(11, .medium)).tracking(0.8)
                        }
                        .foregroundStyle(Gallery.gold)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(18)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entity.name), \(entity.affiliation ?? "person"). \(entity.oneLiner)")
    }

    private var roleBadge: some View {
        Text(badgeText)
            .font(Gallery.mono(10, .semibold))
            .tracking(1.2)
            .foregroundStyle(Gallery.paper)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Gallery.badgeInk.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private var badgeText: String {
        if let a = entity.affiliation, !a.isEmpty {
            return a.uppercased()
        }
        if let c = entity.firstMentionChapter {
            return "PERSON · CH \(c)"
        }
        return "PERSON"
    }

    private var initials: String {
        entity.name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }
}

// MARK: Place (Apple Maps with a wider-region inset)

struct PlaceMapTile: View {
    let place: Entity
    let allPlaces: [Entity]

    private let mainSpanDelta: CLLocationDegrees = 2.6

    private var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude ?? 0, longitude: place.longitude ?? 0)
    }
    private var markers: [Entity] {
        let withCoords = allPlaces.filter { $0.hasCoordinates }
        return withCoords.isEmpty ? [place] : withCoords
    }

    // The four corners of the main map's viewport, drawn as a rectangle on the
    // inset so it shows where the big map sits in the wider region.
    private var mainViewportCorners: [CLLocationCoordinate2D] {
        let half = mainSpanDelta / 2
        let n = center.latitude + half, s = center.latitude - half
        let e = center.longitude + half, w = center.longitude - half
        return [
            CLLocationCoordinate2D(latitude: n, longitude: w),
            CLLocationCoordinate2D(latitude: n, longitude: e),
            CLLocationCoordinate2D(latitude: s, longitude: e),
            CLLocationCoordinate2D(latitude: s, longitude: w),
        ]
    }

    var body: some View {
        ZStack {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: mainSpanDelta, longitudeDelta: mainSpanDelta)
            ))) {
                ForEach(markers) { p in
                    Annotation(p.name, coordinate: CLLocationCoordinate2D(latitude: p.latitude ?? 0, longitude: p.longitude ?? 0)) {
                        MarkerDot(label: p.name)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControlVisibility(.hidden)
            .allowsHitTesting(false)
            .overlay(Gallery.accent.opacity(0.04))

            // Inset: where this sits in the wider region.
            VStack {
                HStack {
                    insetMap
                    Spacer()
                    regionBadge
                }
                Spacer()
            }
            .padding(12)
        }
    }

    private var insetMap: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (place.latitude ?? 0) + 5, longitude: (place.longitude ?? 0) - 4),
            span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30)
        ))) {
            MapPolygon(coordinates: mainViewportCorners)
                .foregroundStyle(Gallery.accent.opacity(0.14))
                .stroke(Gallery.accent, lineWidth: 2)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .allowsHitTesting(false)
        .frame(width: 176, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.25)))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }

    private var regionBadge: some View {
        Text(place.name.uppercased())
            .font(Gallery.mono(10, .semibold))
            .tracking(1.2)
            .foregroundStyle(Gallery.paper)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Gallery.badgeInk.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct MarkerDot: View {
    let label: String
    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Gallery.accent)
                .frame(width: 13, height: 13)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            Text(label)
                .font(Gallery.sans(11, .semibold))
                .foregroundStyle(Gallery.ink)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.14)))
        }
    }
}

struct PlaceTile: View {
    let entity: Entity
    var body: some View {
        WhiteTile(kicker: kickerText, title: entity.name, caption: entity.oneLiner) {
            ZStack {
                Gallery.tileFill
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 40))
                    .foregroundStyle(Gallery.accent.opacity(0.5))
            }
        }
    }
    private var kickerText: String {
        var s = "Place"
        if let c = entity.firstMentionChapter { s += " · Ch \(c)" }
        return s
    }
}

// MARK: Product, Org, Term, Event (white paper cards)

struct ProductTile: View {
    let entity: Entity
    var body: some View {
        WhiteTile(kicker: kickerText, title: entity.name, caption: entity.thenNow ?? entity.oneLiner) {
            ZStack {
                Gallery.panel
                if let url = entity.imageURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fit).padding(22)
                        } else { productGlyph }
                    }
                } else { productGlyph }
            }
        }
    }
    private var productGlyph: some View {
        Image(systemName: "shippingbox").font(.system(size: 40)).foregroundStyle(Gallery.muted.opacity(0.5))
    }
    private var kickerText: String {
        var s = "Product"
        if let c = entity.firstMentionChapter { s += " · Ch \(c)" }
        return s
    }
}

struct OrgTile: View {
    let entity: Entity
    var body: some View {
        WhiteTile(kicker: "Organization", title: entity.name, caption: entity.oneLiner) {
            ZStack {
                Gallery.panel
                if let url = entity.imageURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fit).padding(18)
                        } else { monogram }
                    }
                } else { monogram }
            }
            .padding(16)
        }
    }
    private var monogram: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Gallery.monogram)
            VStack(spacing: 5) {
                Text(initials).font(Gallery.serif(34, .semibold)).foregroundStyle(Gallery.paper)
                Kicker(text: entity.name, color: Gallery.accent, size: 9)
            }
        }
    }
    private var initials: String {
        entity.name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }
}

struct TermTile: View {
    let entity: Entity
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(text: "Term", color: Gallery.accent)
            Text(entity.name)
                .font(Gallery.serif(26, .semibold))
                .foregroundStyle(Gallery.ink)
                .lineLimit(2)
            Text(entity.oneLiner)
                .font(Gallery.sans(13))
                .foregroundStyle(Gallery.inkSoft)
                .lineLimit(5)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Gallery.panel)
    }
}

struct EventTile: View {
    let entity: Entity
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(text: "Event", color: Gallery.accent)
            if let date = entity.dateText {
                Text(date).font(Gallery.mono(15, .semibold)).foregroundStyle(Gallery.ink)
            }
            Text(entity.name)
                .font(Gallery.serif(21, .semibold))
                .foregroundStyle(Gallery.ink)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Gallery.panel)
    }
}

// A white paper card: a media area on top, then a serif title + mono kicker,
// mirroring the design's Power Mac G4 / Foxconn cards.
struct WhiteTile<Media: View>: View {
    let kicker: String
    let title: String
    let caption: String?
    @ViewBuilder let media: () -> Media

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            media()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Gallery.serif(24, .semibold))
                    .foregroundStyle(Gallery.ink)
                    .lineLimit(1)
                Kicker(text: kicker, color: Gallery.accent)
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(Gallery.sans(11.5))
                        .foregroundStyle(Gallery.inkSoft)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 12)
        }
        .background(Gallery.panel)
    }
}
