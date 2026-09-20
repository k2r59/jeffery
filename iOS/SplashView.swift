import SwiftUI
import WebKit

/// Écran de lancement « Ricochets » : l'animation HTML du kit (iOS/Splash/animation.html, canvas, aucun réseau) jouée
/// telle quelle dans une WebView plein écran. L'animation signale sa fin (`jeffrey:splash-complete`, 7,4 s) ; avec la
/// réduction des animations, elle affiche l'image finale et passe la main après 1,2 s.
struct SplashView: View {
    var onDone: () -> Void
    @State private var fadeOut = false
    @State private var done = false
    @State private var ready = false

    var body: some View {
        ZStack {
            Color(red: 0x0B / 255, green: 0x10 / 255, blue: 0x0D / 255).ignoresSafeArea()
            SplashWebView(onReady: { withAnimation(.easeOut(duration: 0.25)) { ready = true } }, onComplete: { finish() })
                .ignoresSafeArea()
            // Le temps que la page se charge, on garde le symbole de l'écran de lancement système : pas de trou noir.
            if !ready {
                Image("jeffrey-symbole-citron").resizable().scaledToFit().frame(width: 84, height: 84)
                    .transition(.opacity)
            }
        }
        .opacity(fadeOut ? 0 : 1)
        .allowsHitTesting(!fadeOut)
        .onAppear {
            // Filet : si la WebView ne répond pas (page absente, JavaScript coupé), on ne bloque pas l'app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { finish() }
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        withAnimation(.easeOut(duration: 0.45)) { fadeOut = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onDone() }
    }
}

private struct SplashWebView: UIViewRepresentable {
    let onReady: () -> Void
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady, onComplete: onComplete) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "splash")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0x0B / 255, green: 0x10 / 255, blue: 0x0D / 255, alpha: 1)
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isUserInteractionEnabled = false
        if let url = Bundle.main.url(forResource: "animation", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            DispatchQueue.main.async { onComplete() }
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onReady: () -> Void
        let onComplete: () -> Void
        init(onReady: @escaping () -> Void, onComplete: @escaping () -> Void) { self.onReady = onReady; self.onComplete = onComplete }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? String
            DispatchQueue.main.async { body == "ready" ? self.onReady() : self.onComplete() }
        }
    }
}
