import SwiftUI

/// Palette « piste de nuit » : noir profond, vert acide pour l'énergie, orange braise pour l'effort.
enum Theme {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.06)
    static let surface = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let surfaceRaised = Color(red: 0.15, green: 0.16, blue: 0.19)
    static let lime = Color(red: 0.78, green: 1.0, blue: 0.22)
    static let ember = Color(red: 1.0, green: 0.42, blue: 0.16)
    static let pulse = Color(red: 1.0, green: 0.23, blue: 0.35)
    static let ice = Color(red: 0.55, green: 0.85, blue: 1.0)
    static let muted = Color.white.opacity(0.55)

    static func zoneColor(_ zone: HeartRateZone?) -> Color {
        switch zone {
        case .z1: return Color(red: 0.45, green: 0.75, blue: 1.0)
        case .z2: return lime
        case .z3: return Color(red: 1.0, green: 0.85, blue: 0.2)
        case .z4: return ember
        case .z5: return pulse
        case nil: return muted
        }
    }

    static var startGradient: LinearGradient {
        LinearGradient(colors: [lime, Color(red: 0.55, green: 0.95, blue: 0.35)], startPoint: .leading, endPoint: .trailing)
    }
}

extension Font {
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
            )
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}
