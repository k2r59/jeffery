import SwiftUI

/// Écran d'accueil au lancement : le J citron respire, le logo et la signature apparaissent, puis fondu vers l'app.
/// Prolonge le launch screen système (même fond, même symbole) pour que l'enchaînement soit continu.
struct SplashView: View {
    var onDone: () -> Void
    @State private var symbolScale: CGFloat = 0.92
    @State private var showWordmark = false
    @State private var fadeOut = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ZStack {
                if !showWordmark {
                    Image("jeffrey-symbole-citron")
                        .resizable().scaledToFit().frame(width: 84, height: 84)
                        .scaleEffect(symbolScale)
                        .transition(.opacity.combined(with: .scale(scale: 1.15)))
                }
                if showWordmark {
                    VStack(spacing: 10) {
                        JeffreyWordmark(size: 44, signature: false)
                        Text("À tes côtés. À ton rythme.")
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.muted)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .opacity(fadeOut ? 0 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { symbolScale = 1.06 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.spring(duration: 0.5)) { showWordmark = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
                withAnimation(.easeOut(duration: 0.45)) { fadeOut = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { onDone() }
        }
        .allowsHitTesting(!fadeOut)
    }
}
