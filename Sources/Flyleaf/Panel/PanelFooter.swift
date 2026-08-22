import SwiftUI
import MapKit

struct PlaceMapView: View {
    let name: String
    let latitude: Double
    let longitude: Double
    var spanDegrees: Double = 6

    var body: some View {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        Map(initialPosition: .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees)
        ))) {
            Marker(name, coordinate: center).tint(.red)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
    }
}

// The one always-available control: "I'm actually at..." chapter override,
// plus sync status at a glance.
struct PanelFooterView: View {
    @Environment(AppState.self) private var state
    var dimmed = false

    var body: some View {
        let prefs = Prefs.shared
        HStack(spacing: 8) {
            syncDot
            if let book = state.currentBook {
                Text(book.title)
                    .font(Theme.footerFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Flyleaf")
                    .font(Theme.footerFont)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if state.manualPin != nil {
                Button {
                    state.manualPin = nil
                    state.recomputeChapter()
                } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Chapter pinned by hand. Click to follow the Kindle again.")
            }
            if state.toc != nil {
                chapterControls
            } else if let percent = state.position?.percent {
                Text("\(Int(percent))%")
                    .font(Theme.footerFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(width: Theme.cardWidth(prefs.panelSize))
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .opacity(dimmed ? 0.55 : 1)
    }

    private var chapterControls: some View {
        HStack(spacing: 4) {
            Button {
                if let chapter = state.currentChapter {
                    state.setManualChapter(chapter - 1)
                }
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled((state.currentChapter ?? 1) <= 1)
            .help("I'm actually at an earlier chapter")

            Text(chapterLabel)
                .font(Theme.footerFont)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            Button {
                if let chapter = state.currentChapter {
                    state.setManualChapter(chapter + 1)
                } else {
                    state.setManualChapter(1)
                }
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled((state.currentChapter ?? 0) >= (state.toc?.maxChapter ?? 1))
            .help("I'm actually at a later chapter")
        }
    }

    private var chapterLabel: String {
        guard let toc = state.toc else { return "" }
        let chapter = state.currentChapter.map(String.init) ?? "?"
        var label = "Ch \(chapter) of \(toc.maxChapter)"
        if let percent = state.position?.percent {
            label += " · \(Int(percent))%"
        }
        return label
    }

    private var syncDot: some View {
        let (color, help): (Color, String) = {
            switch state.connection {
            case .needsReauth: return (.red, "Amazon session expired")
            case .connecting: return (.yellow, "Connecting")
            case .connected:
                if Prefs.shared.paused { return (.gray, "Syncing paused") }
                if let last = state.lastPollAt, Date().timeIntervalSince(last) < 180 {
                    return (.green, "Synced \(relative(last))")
                }
                return (.gray.opacity(0.7), "Idle")
            case .notConnected:
                return (state.currentBook?.isManual == true || state.isDemo)
                    ? (.blue, "Manual mode")
                    : (.gray, "Not connected")
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(help)
    }

    private func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 90 { return "just now" }
        return "\(seconds / 60)m ago"
    }
}
