import SwiftUI

/// Palette officielle Jeffrey (documentation/couleurs.json du pack d'assets).
enum Theme {
    static let citron = Color(red: 0.831, green: 1.0, blue: 0.294)     // #D4FF4B
    static let encre = Color(red: 0.063, green: 0.078, blue: 0.067)    // #101411
    static let creme = Color(red: 0.949, green: 0.941, blue: 0.906)    // #F2F0E7
    static let sauge = Color(red: 0.592, green: 0.643, blue: 0.549)    // #97A48C
    static let surfaceOfficial = Color(red: 0.137, green: 0.169, blue: 0.125) // #232B20
    static let alerte = Color(red: 1.0, green: 0.384, blue: 0.345)     // #FF6258

    // Rôles utilisés dans les vues
    static let background = encre
    static let surface = Color(red: 0.10, green: 0.12, blue: 0.10)
    static let surfaceRaised = surfaceOfficial
    static let lime = citron
    static let ember = Color(red: 1.0, green: 0.55, blue: 0.25)
    static let pulse = alerte
    static let ice = creme
    static let muted = sauge
    static let text = creme

    static func zoneColor(_ zone: HeartRateZone?) -> Color {
        switch zone {
        case .z1: return sauge
        case .z2: return citron
        case .z3: return Color(red: 1.0, green: 0.85, blue: 0.3)
        case .z4: return ember
        case .z5: return alerte
        case nil: return sauge
        }
    }

    static var startGradient: LinearGradient {
        LinearGradient(colors: [citron, Color(red: 0.72, green: 0.95, blue: 0.35)], startPoint: .leading, endPoint: .trailing)
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
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.creme.opacity(0.06)))
            )
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

/// Pictogramme du pack Jeffrey (version crème rendue en gabarit : la couleur vient de `.foregroundStyle`).
struct JIcon: View {
    let name: String
    var size: CGFloat = 18
    init(_ name: String, size: CGFloat = 18) { self.name = name; self.size = size }
    var body: some View {
        Image("\(name)-creme")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
