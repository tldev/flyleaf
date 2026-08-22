import SwiftUI

// Typography tuned for arm's length reading: big serif faces, generous
// spacing, quiet secondary text.
enum Theme {
    static func cardWidth(_ size: PanelSize) -> CGFloat {
        size == .compact ? 300 : 348
    }

    static func nameFont(_ size: PanelSize) -> Font {
        .system(size: size == .compact ? 20 : 24, weight: .semibold, design: .serif)
    }

    static func bodyFont(_ size: PanelSize) -> Font {
        .system(size: size == .compact ? 14 : 16, weight: .regular, design: .serif)
    }

    static func detailFont(_ size: PanelSize) -> Font {
        .system(size: size == .compact ? 12 : 13.5, weight: .regular, design: .serif)
    }

    static let kickerFont = Font.system(size: 11, weight: .semibold).smallCaps()
    static let captionFont = Font.system(size: 11.5, weight: .regular)
    static let footerFont = Font.system(size: 11.5, weight: .medium)

    static func imageSide(_ size: PanelSize) -> CGFloat {
        size == .compact ? 56 : 76
    }

    static let cornerRadius: CGFloat = 18
}

struct CardBackground: ViewModifier {
    var highContrast: Bool

    func body(content: Content) -> some View {
        Group {
            if highContrast {
                content.background(Color(nsColor: .windowBackgroundColor).opacity(0.98))
            } else {
                content.background(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

extension View {
    func cardChrome(highContrast: Bool) -> some View {
        modifier(CardBackground(highContrast: highContrast))
    }
}

struct ShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.35), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: phase * geo.size.width * 1.6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
