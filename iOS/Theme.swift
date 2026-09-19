import SwiftUI

/// Palette officielle Jeffrey (documentation/couleurs.json du pack d'assets).
enum Theme {
    static let citron = JeffreyPalette.citron
    static let encre = JeffreyPalette.encre
    static let creme = JeffreyPalette.creme
    static let sauge = JeffreyPalette.sauge
    static let surfaceOfficial = JeffreyPalette.surface
    static let alerte = JeffreyPalette.alerte

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
    /// Titres et chiffres : SF Pro (police système, sans arrondi), choix d'Hervé du 19/09/2026.
    /// Les graisses « black » de l'arrondi sont ramenées à « heavy », plus équilibrées en SF Pro.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight == .black ? .heavy : weight, design: .default)
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.creme.opacity(0.06)))
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
