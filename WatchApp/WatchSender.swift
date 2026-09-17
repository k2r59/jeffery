import Foundation
import WatchConnectivity
import Combine

/// État de la séance iPhone tel que reçu par la montre.
@MainActor
final class WatchMirror: ObservableObject {
    static let shared = WatchMirror()
    @Published var state: CoachMirror = .idle
    @Published var phoneReachable = false
    @Published var notice: String?
}

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

    /// Demande à l'iPhone de démarrer / mettre en pause / reprendre / terminer la séance Jeffrey.
    func request(_ command: WatchCommand, kind: WorkoutKind, completion: @escaping (Bool) -> Void) {
        let payload = WatchCommandPayload(command: command, kind: kind, mode: .companion)
        guard WCSession.isSupported(), let data = try? WCCodec.encoder.encode(payload) else { completion(false); return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { completion(false); return }
        session.sendMessage([WCKeys.command: data], replyHandler: { _ in
            Task { @MainActor in completion(true) }
        }, errorHandler: { _ in
            Task { @MainActor in completion(false) }
        })
    }

    private func ingestMirror(_ dict: [String: Any]) {
        guard let data = dict[WCKeys.coachState] as? Data,
              let mirror = try? WCCodec.decoder.decode(CoachMirror.self, from: data) else { return }
        Task { @MainActor in
            if WatchMirror.shared.state.timestamp <= mirror.timestamp { WatchMirror.shared.state = mirror }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in WatchMirror.shared.phoneReachable = session.isReachable }
        if !session.receivedApplicationContext.isEmpty { ingestMirror(session.receivedApplicationContext) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in WatchMirror.shared.phoneReachable = session.isReachable }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        ingestMirror(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        ingestMirror(message)
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
