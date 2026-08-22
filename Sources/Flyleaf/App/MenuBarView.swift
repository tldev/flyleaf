import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bookHeader
            Divider().padding(.vertical, 8)
            if state.connection == .needsReauth {
                reauthRow
                Divider().padding(.vertical, 8)
            }
            actions
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: Header

    @ViewBuilder
    private var bookHeader: some View {
        if let book = state.currentBook {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: book.coverURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                            .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
                    }
                }
                .frame(width: 42, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .lineLimit(2)
                    if !book.authorLine.isEmpty {
                        Text(book.authorLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let percent = state.position?.percent {
                        ProgressView(value: percent, total: 100)
                            .controlSize(.small)
                            .tint(.accentColor)
                    }
                    Text(syncLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("No book yet")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Get started") { WindowManager.shared.showOnboarding() }
                    .controlSize(.small)
            }
        }
    }

    private var syncLine: String {
        var parts = [String]()
        if let percent = state.position?.percent {
            var line = "\(Int(percent))%"
            if let chapter = state.currentChapter, let toc = state.toc {
                line = "Ch \(chapter) of \(toc.maxChapter) · \(line)"
            }
            parts.append(line)
        }
        if state.currentBook?.isManual == true {
            parts.append("manual mode")
        } else if let position = state.position {
            var sync = "synced \(relative(position.syncedAt))"
            if let device = position.deviceName, !device.isEmpty {
                sync += " from \(device)"
            }
            parts.append(sync)
        }
        if let message = state.statusMessage {
            parts.append(message)
        }
        return parts.joined(separator: " · ")
    }

    private func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    private var reauthRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Amazon needs a fresh sign-in")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Re-connect") { WindowManager.shared.showLogin() }
                .controlSize(.small)
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuRow(symbol: "macwindow", title: "Open Flyleaf") {
                WindowManager.shared.showMain()
            }
            MenuRow(symbol: Prefs.shared.panelVisible ? "eye.slash" : "eye", title: Prefs.shared.panelVisible ? "Hide floating panel" : "Show floating panel") {
                PanelController.shared.toggle()
            }
            if state.connection == .connected {
                MenuRow(symbol: Prefs.shared.paused ? "play.fill" : "pause.fill", title: Prefs.shared.paused ? "Resume syncing" : "Pause syncing") {
                    Prefs.shared.paused.toggle()
                    if !Prefs.shared.paused { state.poller.pollSoon() }
                }
                MenuRow(symbol: "arrow.clockwise", title: "Sync now") {
                    state.poller.pollSoon()
                }
            }
            if let toc = state.toc, state.currentBook != nil {
                chapterPicker(toc: toc)
            }
            MenuRow(symbol: "questionmark.bubble", title: "Ask…  (⌥⌘K)") {
                WindowManager.shared.showAsk()
            }
            MenuRow(symbol: "memories", title: "Previously On…") {
                WindowManager.shared.showRecap()
            }
            MenuRow(symbol: "arrow.left.arrow.right", title: "Switch book…") {
                WindowManager.shared.showManualPicker()
            }
            MenuRow(symbol: "gearshape", title: "Settings…") {
                WindowManager.shared.showSettings()
            }
            MenuRow(symbol: "power", title: "Quit Flyleaf") {
                NSApp.terminate(nil)
            }
        }
    }

    private func chapterPicker(toc: BookTOC) -> some View {
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
            HStack(spacing: 8) {
                Image(systemName: "text.book.closed")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text("I'm actually at…")
                    .font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let stats = state.statsSummary, stats.minutesToday >= 1 || stats.streakDays > 0 {
            var parts: [String] {
                var p = [String]()
                if stats.minutesToday >= 1 { p.append("today \(Int(stats.minutesToday))m") }
                if let rate = stats.ratePerHour { p.append(String(format: "%.1f%%/hr", rate)) }
                if stats.streakDays > 0 { p.append("streak \(stats.streakDays)d") }
                if let finish = stats.projectedFinish {
                    p.append("finish ~\(finish.formatted(.dateTime.month(.abbreviated).day()))")
                }
                return p
            }
            Text(parts.joined(separator: " · "))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        } else {
            Text("Flyleaf follows your Kindle as you read.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }
}

struct MenuRow: View {
    let symbol: String
    let title: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(hovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovered = $0 }
    }
}
