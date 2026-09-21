import SwiftUI

/// Pictogramme du pack Jeffrey (version crème rendue en gabarit : la couleur vient de `.foregroundStyle`).
/// Même vue sur l'iPhone et la montre ; seule la taille par défaut diffère.
struct JIcon: View {
    let name: String
    var size: CGFloat
    init(_ name: String, size: CGFloat = JIcon.defaultSize) { self.name = name; self.size = size }

    #if os(watchOS)
    static let defaultSize: CGFloat = 14
    #else
    static let defaultSize: CGFloat = 18
    #endif

    var body: some View {
        Image("\(name)-creme")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
