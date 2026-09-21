import SwiftUI

/// Le symbole Jeffrey (assets officiels) et ses états : disponible, à l'écoute, te parle.
enum JeffreyState {
    case available
    case listening
    case speaking
}

struct JeffreyMark: View {
    var state: JeffreyState = .available
    var size: CGFloat = 40

    @State private var pulse = false

    private var assetName: String {
        switch state {
        case .available: return "jeffrey-symbole-citron"
        case .listening: return "jeffrey-coach-ecoute-citron"
        case .speaking: return "jeffrey-coach-parle-citron"
        }
    }

    var body: some View {
        Image(assetName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .scaleEffect(state == .available ? 1 : (pulse ? 1.04 : 0.98))
            .opacity(state == .speaking ? (pulse ? 1 : 0.85) : 1)
            .onAppear { restartPulse() }
            .onChange(of: stateKey) { _, _ in restartPulse() }
    }

    private var stateKey: Int {
        switch state { case .available: return 0; case .listening: return 1; case .speaking: return 2 }
    }

    private func restartPulse() {
        pulse = false
        guard state != .available else { return }
        withAnimation(.easeInOut(duration: state == .speaking ? 0.35 : 0.9).repeatForever(autoreverses: true)) { pulse = true }
    }
}

/// Logotype officiel : J citron intégré + « effrey » crème (ou encre sur fond clair).
struct JeffreyWordmark: View {
    var size: CGFloat = 22
    var signature: Bool = false

    var body: some View {
        Image(signature ? "jeffrey-logo-signature-creme" : "jeffrey-logo-creme")
            .resizable()
            .scaledToFit()
            .frame(height: size * (signature ? 1.9 : 1.3))
    }
}
