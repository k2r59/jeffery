import SwiftUI

/// Pictogramme du pack (gabarit crème) côté montre.
struct JIcon: View {
    let name: String
    var size: CGFloat = 14
    init(_ name: String, size: CGFloat = 14) { self.name = name; self.size = size }
    var body: some View {
        Image("\(name)-creme").renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
    }
}
