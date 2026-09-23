import SwiftUI

/// Balayage vers la gauche sur une ligne : découvre un bouton Supprimer. Fonctionne hors `List`, où
/// `swipeActions` n'est pas disponible (nos listes sont des `ScrollView` pour garder la mise en page).
struct SwipeToDelete<Content: View>: View {
    var onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @GestureState private var drag: CGFloat = 0
    private let width: CGFloat = 92

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: { reset(); onDelete() }) {
                VStack(spacing: 4) {
                    JIcon("fermer", size: 16)
                    Text("Supprimer").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.alerte))
            }
            .buttonStyle(.plain)
            .opacity(shown > 8 ? 1 : 0)

            content()
                .offset(x: -shown)
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .updating($drag) { value, state, _ in
                            // Seulement horizontal : le défilement vertical reste prioritaire.
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            state = value.translation.width
                        }
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            withAnimation(.snappy) { offset = value.translation.width < -width / 2 ? width : 0 }
                        }
                )
        }
        .animation(.snappy, value: shown)
    }

    private var shown: CGFloat { max(0, min(width, offset - drag)) }
    private func reset() { withAnimation(.snappy) { offset = 0 } }
}
