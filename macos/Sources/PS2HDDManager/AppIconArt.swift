import SwiftUI

/// App icon artwork, drawn in SwiftUI so the same file renders the .icns (see make_icon.sh)
/// and the welcome screen. Self-contained: no dependencies on the rest of the app.
struct AppIconArt: View {
    var size: CGFloat = 512

    var body: some View {
        let s = size
        ZStack {
            // Squircle background: deep console blue.
            RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.38, blue: 0.98), Color(red: 0.05, green: 0.09, blue: 0.32)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                .fill(RadialGradient(colors: [.white.opacity(0.28), .clear], center: .init(x: 0.3, y: 0.15),
                                     startRadius: 0, endRadius: s * 0.7))

            // Hard drive slab.
            RoundedRectangle(cornerRadius: s * 0.07, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                .frame(width: s * 0.66, height: s * 0.26)
                .overlay(alignment: .trailing) {
                    HStack(spacing: s * 0.025) {
                        ForEach(0..<3) { _ in Capsule().fill(Color(white: 0.45)).frame(width: s * 0.012, height: s * 0.09) }
                        Circle().fill(Color(red: 0.35, green: 1.0, blue: 0.55))
                            .frame(width: s * 0.035).shadow(color: .green, radius: s * 0.02)
                    }
                    .padding(.trailing, s * 0.05)
                }
                .shadow(color: .black.opacity(0.45), radius: s * 0.03, y: s * 0.02)
                .offset(y: s * 0.21)

            // Disc rising out of the drive.
            ZStack {
                Circle().fill(AngularGradient(colors: [
                    Color(white: 0.95), Color(red: 1.0, green: 0.82, blue: 0.62), Color(red: 0.75, green: 0.70, blue: 1.0),
                    Color(red: 0.55, green: 0.90, blue: 1.0), Color(white: 0.85), Color(red: 1.0, green: 0.75, blue: 0.85),
                    Color(white: 0.95)], center: .center))
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: s * 0.006).padding(s * 0.09)
                Circle().strokeBorder(.white.opacity(0.25), lineWidth: s * 0.004).padding(s * 0.15)
                Circle().fill(Color(white: 0.75)).frame(width: s * 0.17)
                Circle().fill(Color(red: 0.07, green: 0.12, blue: 0.38)).frame(width: s * 0.075)
            }
            .frame(width: s * 0.52, height: s * 0.52)
            .shadow(color: .black.opacity(0.35), radius: s * 0.04, y: s * 0.02)
            .offset(y: -s * 0.07)
        }
        .frame(width: s, height: s)
    }
}
