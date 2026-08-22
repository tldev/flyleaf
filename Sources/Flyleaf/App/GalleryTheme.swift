import SwiftUI

// The "Glance Gallery" aesthetic from the Claude Design reimagining: a warm
// paper surface, editorial serif display type, monospaced uppercase labels,
// and a single burnt-orange accent. A committed light look, so colors are
// explicit rather than semantic.
enum Gallery {
    static let paper = Color(hex: 0xF4F1EA)
    static let panel = Color.white
    static let ink = Color(hex: 0x1F1C15)
    static let inkSoft = Color(hex: 0x6F6753)
    static let muted = Color(hex: 0x8B8371)
    static let wordmark = Color(hex: 0x8A7C5C)
    static let accent = Color(hex: 0xB45309)
    static let gold = Color(hex: 0xEEC584)
    static let border = Color(hex: 0xDDD3BA)
    static let divider = Color(hex: 0xE2DBC9)
    static let tileFill = Color(hex: 0xE6DFCC)
    static let monogram = Color(hex: 0x17150F)
    static let badgeInk = Color(hex: 0x140E06)

    // Type: system serif stands in for Newsreader, monospaced for IBM Plex
    // Mono, the default sans for Archivo. Close in character and fully native.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func serifItalic(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif).italic()
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// A mono, letter-spaced, uppercase label (the design's role/kind chips).
struct Kicker: View {
    let text: String
    var color: Color = Gallery.accent
    var size: CGFloat = 10.5
    var body: some View {
        Text(text.uppercased())
            .font(Gallery.mono(size, .semibold))
            .tracking(1.4)
            .foregroundStyle(color)
    }
}

// MARK: Tile model

enum GalleryTileKind {
    case person, placeMap, place, product, org, term, event
}

struct GalleryTile: Identifiable {
    let entity: Entity
    let kind: GalleryTileKind
    let span: Int
    var id: String { entity.id }
}

enum GalleryLayout {
    static let columns = 6

    // Assigns a tile kind and column span to each entity. All coordinate
    // places collapse onto ONE map (the rest are markers on it, not tiles);
    // events live in the Timeline tab, not the gallery. Tiles are then ordered
    // like the design: people first, then map, product, org, other places,
    // terms.
    static func tiles(from entities: [Entity]) -> [GalleryTile] {
        var usedMap = false
        var out = [GalleryTile]()
        for e in entities {
            switch e.kind {
            case .person:
                out.append(GalleryTile(entity: e, kind: .person, span: 2))
            case .place:
                if e.hasCoordinates {
                    if !usedMap {
                        usedMap = true
                        out.append(GalleryTile(entity: e, kind: .placeMap, span: 3))
                    }
                    // Other mapped places are markers on the one map, no tile.
                } else {
                    out.append(GalleryTile(entity: e, kind: .place, span: 2))
                }
            case .product:
                out.append(GalleryTile(entity: e, kind: .product, span: 2))
            case .organization:
                out.append(GalleryTile(entity: e, kind: .org, span: 1))
            case .term:
                out.append(GalleryTile(entity: e, kind: .term, span: 2))
            case .event:
                break
            }
        }
        let priority: [GalleryTileKind: Int] = [.person: 0, .placeMap: 1, .product: 2, .org: 3, .place: 4, .term: 5]
        return out.enumerated()
            .sorted { a, b in
                let pa = priority[a.element.kind] ?? 9, pb = priority[b.element.kind] ?? 9
                return pa == pb ? a.offset < b.offset : pa < pb
            }
            .map { $0.element }
    }

    // Greedy first-fit packing into rows of `columns`, preserving rank order.
    static func rows(_ tiles: [GalleryTile]) -> [[GalleryTile]] {
        var rows = [[GalleryTile]]()
        var current = [GalleryTile]()
        var used = 0
        for tile in tiles {
            let span = min(tile.span, columns)
            if used + span > columns {
                if !current.isEmpty { rows.append(current) }
                current = [tile]
                used = span
            } else {
                current.append(tile)
                used += span
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    // People rows are the tallest (portrait), media rows a touch shorter,
    // all-textual rows short.
    static func rowHeight(_ row: [GalleryTile]) -> CGFloat {
        if row.contains(where: { $0.kind == .person }) { return 452 }
        if row.contains(where: { $0.kind == .placeMap || $0.kind == .product || $0.kind == .place }) { return 400 }
        return 300
    }
}
