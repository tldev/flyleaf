import SwiftUI
import MapKit

// The accumulated-context tabs of the main window: everyone met so far, a
// map of every place, dated events, and the object gallery. Always scoped
// to packs through the current chapter, so never a spoiler.

func dedupeEntities(_ entities: [Entity]) -> [Entity] {
    var seen = [String: Entity]()
    for e in entities {
        if let existing = seen[e.name] {
            if (e.firstMentionChapter ?? .max) < (existing.firstMentionChapter ?? .max) {
                seen[e.name] = e
            }
        } else {
            seen[e.name] = e
        }
    }
    return Array(seen.values)
}

struct CastTab: View {
    let packs: [ContextPack]

    var body: some View {
        let people = dedupeEntities(packs.flatMap { $0.entities.filter { $0.kind == .person } })
        let groups = Dictionary(grouping: people) { $0.affiliation ?? "Elsewhere" }
            .sorted { $0.value.count > $1.value.count }

        if people.isEmpty {
            ContentUnavailableView(
                "No people yet",
                systemImage: "person.2",
                description: Text("People appear here as chapters introduce them.")
            )
        } else {
            List {
                ForEach(groups, id: \.key) { group in
                    Section(group.key) {
                        ForEach(group.value.sorted { ($0.firstMentionChapter ?? 0) < ($1.firstMentionChapter ?? 0) }) { person in
                            EntityRow(entity: person)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

struct EntityRow: View {
    let entity: Entity

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: entity.imageURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Circle().fill(.quaternary)
                        Image(systemName: entity.kind.symbolName).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(entity.name).font(.system(size: 14, weight: .semibold, design: .serif))
                    if let pronunciation = entity.pronunciation {
                        Button {
                            Speech.say(pronunciation)
                        } label: {
                            Image(systemName: "speaker.wave.2").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Text(entity.oneLiner)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let first = entity.firstMentionChapter {
                Text("Ch \(first)")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            ForEach(entity.sourceURLs.prefix(3), id: \.absoluteString) { url in
                Button("Open \(url.host ?? "source")") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

struct AtlasTab: View {
    let packs: [ContextPack]

    var body: some View {
        let places = dedupeEntities(packs.flatMap { $0.entities.filter { $0.kind == .place && $0.hasCoordinates } })
        if places.isEmpty {
            ContentUnavailableView(
                "No places yet",
                systemImage: "map",
                description: Text("Every mapped place you read about lands here.")
            )
        } else {
            Map(initialPosition: .automatic) {
                ForEach(places) { place in
                    Marker(place.name, coordinate: CLLocationCoordinate2D(
                        latitude: place.latitude ?? 0,
                        longitude: place.longitude ?? 0
                    ))
                    .tint(.red)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .overlay(alignment: .bottomLeading) {
                Text("\(places.count) place\(places.count == 1 ? "" : "s") so far")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
            }
        }
    }
}

struct TimelineTab: View {
    let packs: [ContextPack]

    var body: some View {
        let events = packs.flatMap { pack in
            pack.entities
                .filter { $0.kind == .event || $0.dateText != nil }
                .map { (pack.chapter, $0) }
        }
        let sorted = events.sorted { a, b in
            (a.1.sortDate ?? "9999") < (b.1.sortDate ?? "9999")
        }

        if sorted.isEmpty {
            ContentUnavailableView(
                "No dated events yet",
                systemImage: "calendar",
                description: Text("Dated events from your reading collect here in order.")
            )
        } else {
            List(sorted, id: \.1.id) { chapter, event in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(event.dateText ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.name).font(.system(size: 14, weight: .medium, design: .serif))
                        if !event.oneLiner.isEmpty {
                            Text(event.oneLiner).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("Ch \(chapter)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
        }
    }
}

struct ObjectsTab: View {
    let packs: [ContextPack]

    var body: some View {
        let objects = dedupeEntities(packs.flatMap { pack in
            pack.entities.filter { ($0.kind == .product || $0.kind == .organization || $0.kind == .term) && $0.imageURL != nil }
        })
        if objects.isEmpty {
            ContentUnavailableView(
                "No objects yet",
                systemImage: "shippingbox",
                description: Text("Products and artifacts with imagery appear here.")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(objects) { object in
                        VStack(spacing: 6) {
                            AsyncImage(url: object.imageURL) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Rectangle().fill(.quaternary)
                                }
                            }
                            .frame(height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(object.name)
                                .font(.system(size: 12.5, weight: .medium, design: .serif))
                                .lineLimit(1)
                        }
                        .onTapGesture {
                            if let url = object.sourceURLs.first { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                .padding(14)
            }
        }
    }
}

struct StatsTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            if let stats = state.statsSummary {
                Section("Today") {
                    LabeledContent("Reading time", value: stats.minutesToday < 1 ? "None yet" : "\(Int(stats.minutesToday)) min")
                    LabeledContent("Progress", value: String(format: "%.1f%%", stats.percentToday))
                }
                Section("Pace") {
                    LabeledContent("Speed", value: stats.ratePerHour.map { String(format: "%.1f%% per hour", $0) } ?? "Not enough data yet")
                    LabeledContent("Projected finish", value: stats.projectedFinish.map {
                        $0.formatted(date: .abbreviated, time: .omitted)
                    } ?? "Keep reading to find out")
                    LabeledContent("Streak", value: stats.streakDays == 0 ? "Start one today" : "\(stats.streakDays) day\(stats.streakDays == 1 ? "" : "s")")
                    LabeledContent("Sessions detected", value: "\(stats.sessionCount)")
                }
                Section {
                    Text("Sessions are inferred from Whispersync position changes, so short phone-checks of the book count too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView(
                    "No stats yet",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Read for a bit and pace, streaks, and a projected finish date appear.")
                )
            }
        }
        .formStyle(.grouped)
    }
}
