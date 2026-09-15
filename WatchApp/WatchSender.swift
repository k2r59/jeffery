import Foundation
import WatchConnectivity

/// Canal montre → iPhone (métriques) et iPhone → montre (commandes).
final class WatchSender: NSObject, WCSessionDelegate {
    static let shared = WatchSender()

    private var lastQueuedAt: Date = .distantPast

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(_ snapshot: MetricsSnapshot) {
        guard WCSession.isSupported(), let data = try? WCCodec.encoder.encode(snapshot) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let payload: [String: Any] = [WCKeys.metrics: data]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                self.queueFallback(payload)
            }
        } else {
            queueFallback(payload)
        }
    }

    /// Quand l'iPhone n'est pas joignable : file de transfert (livrée dès que possible), au plus une toutes les 5 s.
    private func queueFallback(_ payload: [String: Any]) {
        let session = WCSession.default
        try? session.updateApplicationContext(payload)
        let now = Date()
        guard now.timeIntervalSince(lastQueuedAt) >= 5 else { return }
        lastQueuedAt = now
        session.transferUserInfo(payload)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleCommand(in: message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleCommand(in: message)
        replyHandler(["ok": true])
    }

    private func handleCommand(in message: [String: Any]) {
        guard let data = message[WCKeys.command] as? Data,
              let payload = try? WCCodec.decoder.decode(WatchCommandPayload.self, from: data) else { return }
        Task { @MainActor in
            WorkoutManager.shared.handle(command: payload)
        }
    }
}
