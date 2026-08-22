import SwiftUI

// One-off spoiler-safe question box, reachable via Option-Command-K.
struct AskView: View {
    @Environment(AppState.self) private var state

    @State private var question = ""
    @State private var answer: String?
    @State private var sources: [URL] = []
    @State private var busy = false
    @State private var errorText: String?
    @State private var useWeb = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(placeholder, text: $question)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .onSubmit(submit)
                    .disabled(busy)
                Button {
                    submit()
                } label: {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.title3)
                    }
                }
                .buttonStyle(.plain)
                .disabled(busy || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Toggle("Search the web for the answer", isOn: $useWeb)
                .font(.caption)
                .toggleStyle(.checkbox)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !state.hasBuilderKey {
                        Label("Add your Anthropic API key in Settings to use Ask.", systemImage: "key")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Open Settings") { WindowManager.shared.showSettings() }
                    } else if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    } else if let answer {
                        Text(answer)
                            .font(.system(size: 15, design: .serif))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if !sources.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Sources").font(Theme.kickerFont).foregroundStyle(.secondary)
                                ForEach(sources.prefix(4), id: \.absoluteString) { url in
                                    Link(url.host ?? url.absoluteString, destination: url)
                                        .font(.caption)
                                }
                            }
                            .padding(.top, 4)
                        }
                    } else if busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking, spoiler-safely…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(contextLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(minWidth: 500, minHeight: 340)
    }

    private var placeholder: String {
        state.currentBook.map { "Ask about \($0.title)…" } ?? "Ask anything…"
    }

    private var contextLine: String {
        guard let book = state.currentBook else {
            return "Answers are kept spoiler free for wherever you are in your book."
        }
        let chapter = state.currentChapter.map { " through chapter \($0)" } ?? ""
        return "Answers use only \(book.title)\(chapter). No spoilers."
    }

    private func submit() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !busy else { return }
        guard let client = AnthropicClient.fromKeychain() else { return }
        busy = true
        answer = nil
        sources = []
        errorText = nil
        let builder = PackBuilder(client: client)
        let book = state.currentBook
        let chapter = state.currentChapter
        let web = useWeb
        Task {
            do {
                let result = try await builder.ask(question: q, book: book, chapter: chapter, useWeb: web)
                answer = result.answer
                sources = result.sources
            } catch {
                errorText = "\(error)"
            }
            busy = false
        }
    }
}

// Previously On: a recap up to the exact position, for returning readers.
struct RecapView: View {
    @Environment(AppState.self) private var state

    @State private var recap: String?
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let book = state.currentBook {
                Text(book.title)
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                Text("Previously, through chapter \(state.currentChapter.map(String.init) ?? "…")")
                    .font(Theme.kickerFont)
                    .foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !state.hasBuilderKey {
                        Label("Add your Anthropic API key in Settings for recaps.", systemImage: "key")
                            .foregroundStyle(.secondary)
                    } else if busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Remembering where you were…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if let recap {
                        Text(recap)
                            .font(.system(size: 16, design: .serif))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Refresh recap", action: generate)
                    .disabled(busy || !state.hasBuilderKey || state.currentBook == nil)
            }
        }
        .padding(18)
        .frame(minWidth: 480, minHeight: 400)
        .onAppear {
            if recap == nil { generate() }
        }
    }

    private func generate() {
        guard let book = state.currentBook, let chapter = state.currentChapter,
              let client = AnthropicClient.fromKeychain(), !busy else { return }
        busy = true
        errorText = nil
        let briefings = state.accumulatedPacks().compactMap { pack -> (chapter: Int, text: String)? in
            guard let briefing = pack.briefing else { return nil }
            return (pack.chapter, briefing)
        }
        let builder = PackBuilder(client: client)
        Task {
            do {
                recap = try await builder.recap(book: book, briefings: briefings, through: chapter)
            } catch {
                errorText = "\(error)"
            }
            busy = false
        }
    }
}
