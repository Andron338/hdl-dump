import SwiftUI

/// Visual language: deep "console blue", discs drawn as iridescent platters (silver CD, blue DVD).
enum Theme {
    static let accent = Color(red: 0.22, green: 0.42, blue: 1.0)
    static let accentDeep = Color(red: 0.07, green: 0.13, blue: 0.40)
    static let system = Color.secondary.opacity(0.45)

    static var heroGradient: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var tileGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.30, green: 0.52, blue: 1.0), accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func mb(_ v: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(v) * 1024 * 1024, countStyle: .binary)
    }
}

/// A shiny optical disc. CDs are silver with a warm sheen, DVDs blue-violet.
struct DiscIcon: View {
    var isDVD: Bool
    var size: CGFloat = 30
    var dimmed = false

    var body: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: sheen, center: .center))
            Circle().strokeBorder(.white.opacity(0.25), lineWidth: size * 0.02).padding(size * 0.18)
            Circle().fill(.black.opacity(0.18)).frame(width: size * 0.34)
            Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: size * 0.16)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: size * 0.06, y: size * 0.03)
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.5 : 1)
    }

    private var sheen: [Color] {
        isDVD
            ? [Color(red: 0.36, green: 0.45, blue: 1.0), Color(red: 0.62, green: 0.40, blue: 0.95), Color(red: 0.30, green: 0.75, blue: 0.95),
               Color(red: 0.25, green: 0.35, blue: 0.90), Color(red: 0.36, green: 0.45, blue: 1.0)]
            : [Color(white: 0.92), Color(red: 1.0, green: 0.86, blue: 0.66), Color(white: 0.78), Color(red: 0.70, green: 0.88, blue: 1.0),
               Color(white: 0.85), Color(white: 0.92)]
    }
}

/// Rounded square tile with a symbol, used for drives.
struct DriveTile: View {
    var systemImage: String
    var isPS2: Bool
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(isPS2 ? AnyShapeStyle(Theme.tileGradient) : AnyShapeStyle(Color.secondary.opacity(0.18)))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(isPS2 ? .white : .secondary)
            )
            .shadow(color: isPS2 ? Theme.accent.opacity(0.35) : .clear, radius: 4, y: 2)
    }
}

/// Segmented capacity bar: system partitions, games, free.
struct CapacityBar: View {
    let totalMB: UInt64
    let gamesMB: UInt64
    let systemMB: UInt64
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let total = Double(max(totalMB, 1))
            let sysW = geo.size.width * Double(systemMB) / total
            let gamesW = geo.size.width * Double(gamesMB) / total
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.system).frame(width: sysW)
                    Rectangle().fill(LinearGradient(colors: [Theme.accent, Color(red: 0.55, green: 0.40, blue: 1.0)],
                                                    startPoint: .leading, endPoint: .trailing))
                        .frame(width: gamesW)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: gamesMB)
    }
}

struct LegendDot: View {
    let color: AnyShapeStyle
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

/// Small rounded label, e.g. a game ID.
struct Pill: View {
    let text: String
    var tint: Color = .secondary
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? .caption.monospaced() : .caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}

extension PS2Contents {
    /// HDL allocates whole 128 MB chunks per game (plus one for the header).
    var gamesMB: UInt64 { games.reduce(0) { $0 + (($1.sizeKB / 1024 + 127) / 128 + 1) * 128 } }
    var systemMB: UInt64 { usedMB > gamesMB ? usedMB - gamesMB : 0 }
}
