import SwiftUI

// Manual Mode: pick any book, scrub chapters, everything downstream is
// identical. Also the fallback when auto-detection finds nothing.
struct ManualBookView: View {
    @Environment(AppState.self) private var state

    @State private var title = ""
    @State private var author = ""
    @State private var asin = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a book")
                .font(.system(size: 22, weight: .semibold, design: .serif))

            if !state.library.isEmpty {
                Text("From your Kindle library")
                    .font(Theme.kickerFont)
                    .foregroundStyle(.secondary)
                List(state.library.prefix(30)) { book in
                    Button {
                        state.switchTo(book: book)
                        WindowManager.shared.close(id: "manual")
                        PanelController.shared.show()
                    } label: {
                        HStack(spacing: 10) {
                            AsyncImage(url: book.coverURL) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().aspectRatio(contentMode: .fit)
                                } else {
                                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                                }
                            }
                            .frame(width: 26, height: 40)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(book.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(book.authorLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 190)
                Divider()
            }

            Text("Or any book at all")
                .font(Theme.kickerFont)
                .foregroundStyle(.secondary)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("Author", text: $author)
                .textFieldStyle(.roundedBorder)
            TextField("ASIN (optional, from the Amazon page URL)", text: $asin)
                .textFieldStyle(.roundedBorder)
            Text("Flyleaf finds the chapters, you set where you are with the panel's chapter control.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Start") {
                    state.startManualBook(
                        title: title.trimmingCharacters(in: .whitespaces),
                        author: author.trimmingCharacters(in: .whitespaces),
                        asin: asin.isEmpty ? nil : asin
                    )
                    WindowManager.shared.close(id: "manual")
                    PanelController.shared.show()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}
