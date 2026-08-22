import SwiftUI

// Book picker: owned Kindle books, emailed/sideloaded personal documents, or
// any book by title. Personal documents follow their real position when
// document sync is on; otherwise you scrub the chapter yourself.
struct ManualBookView: View {
    @Environment(AppState.self) private var state

    @State private var title = ""
    @State private var author = ""
    @State private var asin = ""
    @State private var loadingDocs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a book")
                .font(.system(size: 22, weight: .semibold, design: .serif))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !state.library.isEmpty {
                        section("From your Kindle library") {
                            ForEach(state.library.prefix(40)) { book in
                                bookRow(book, symbol: "book.closed") {
                                    state.switchTo(book: book)
                                    finish()
                                }
                            }
                        }
                    }

                    personalDocsSection

                    section("Or any book at all") {
                        VStack(spacing: 8) {
                            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                            TextField("Author", text: $author).textFieldStyle(.roundedBorder)
                            TextField("ASIN (optional)", text: $asin).textFieldStyle(.roundedBorder)
                            HStack {
                                Text("Flyleaf finds the chapters; you set where you are.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Start") {
                                    state.startManualBook(
                                        title: title.trimmingCharacters(in: .whitespaces),
                                        author: author.trimmingCharacters(in: .whitespaces),
                                        asin: asin.isEmpty ? nil : asin
                                    )
                                    finish()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 560, height: 560)
        .task {
            loadingDocs = true
            await state.loadPickerDocs()
            loadingDocs = false
        }
    }

    @ViewBuilder
    private var personalDocsSection: some View {
        section("Emailed & sideloaded (personal documents)") {
            if loadingDocs && state.pickerDocs.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for your personal documents…").font(.caption).foregroundStyle(.secondary)
                }
            } else if state.pickerDocs.isEmpty {
                Text("None found on your account.").font(.caption).foregroundStyle(.secondary)
            } else {
                if !state.deviceRegistered {
                    Text("Pick one to follow it. To sync its exact position automatically, enable document sync in Settings, Account.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                }
                ForEach(state.pickerDocs.prefix(60)) { book in
                    bookRow(book, symbol: "envelope") {
                        state.switchToPersonalDoc(book)
                        finish()
                    }
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.kickerFont).foregroundStyle(.secondary)
            content()
        }
    }

    private func bookRow(_ book: BookRef, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AsyncImage(url: book.coverURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                            .overlay(Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary))
                    }
                }
                .frame(width: 26, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !book.authorLine.isEmpty {
                        Text(book.authorLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func finish() {
        WindowManager.shared.close(id: "manual")
        WindowManager.shared.showMain()
    }
}
