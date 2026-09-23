import Foundation
import WatchConnectivity
import Combine
import os

/// État de la séance iPhone tel que reçu par la montre.
@MainActor
final class WatchMirror: ObservableObject {
    static let shared = WatchMirror()
    @Published var state: CoachMirror = .idle
    @Published var phoneReachable = false
    @Published var notice: String?
    /// Dernier ping vers l'iPhone (diagnostic) : « ok », ou la raison de l'échec.
    @Published var lastPing = "aucun"
}

/// Canal montre → iPhone (métriques) et iPhone → montre (commandes).
final class WatchSender: NSObject, WCSessionDelegate {
    static let shared = WatchSender()

    private var lastQueuedAt: Date = .distantPast
    private var lastHandledCommandAt: Double = 0
    private var lastSentState: SessionState?
    private let stateLock = NSLock()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private var pingTimer: Timer?
    private let logger = Logger(subsystem: "dev.promo.watchcoach", category: "watch")

    /// App montre ouverte : signe de vie toutes les 5 s, pour que l'iPhone affiche « connectée » (sa notion de
    /// joignabilité ne tient qu'au premier plan de l'app montre).
    func startPinging() {
        pingTimer?.invalidate()
        ping()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.ping() }
    }

    func stopPinging() {
        pingTimer?.invalidate(); pingTimer = nil
    }

    private func ping() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { note("session non activée"); return }
        guard session.isReachable else { note("iPhone injoignable"); return }
        session.sendMessage([WCKeys.ping: 1], replyHandler: { [weak self] _ in self?.note("ok") },
                            errorHandler: { [weak self] error in self?.note("échec : \(error.localizedDescription)") })
    }

    private func note(_ result: String) {
        logger.notice("ping : \(result, privacy: .public)")
        Task { @MainActor in WatchMirror.shared.lastPing = result }
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

    /// Quand l'iPhone n'est pas joignable : contexte (dernier état) toujours ; file de transfert seulement aux transitions.
    private func queueFallback(_ payload: [String: Any]) {
        let session = WCSession.default
        try? session.updateApplicationContext(payload)
        guard let data = payload[WCKeys.metrics] as? Data, let snap = try? WCCodec.decoder.decode(MetricsSnapshot.self, from: data) else { return }
        stateLock.lock(); defer { stateLock.unlock() }
        guard snap.state != lastSentState || Date().timeIntervalSince(lastQueuedAt) >= 60 else { return }
        lastSentState = snap.state
        lastQueuedAt = Date()
        session.transferUserInfo(payload)
    }

    // MARK: WCSessionDelegate

    /// Demande à l'iPhone de démarrer / mettre en pause / reprendre / terminer la séance Jeffrey.
    /// Demande à l'iPhone ; `completion` reçoit nil si accepté, sinon la raison à afficher (iPhone injoignable ou refus
    /// explicite de l'iPhone, par exemple quand il n'affiche pas « Montre connectée »).
    func request(_ command: WatchCommand, kind: WorkoutKind, text: String? = nil, completion: @escaping (String?) -> Void) {
        let unreachable = "iPhone injoignable : ouvre Jeffrey sur l'iPhone"
        let payload = WatchCommandPayload(command: command, kind: kind, mode: .companion, text: text)
        guard WCSession.isSupported(), let data = try? WCCodec.encoder.encode(payload) else { completion(unreachable); return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { completion(unreachable); return }
        session.sendMessage([WCKeys.command: data], replyHandler: { reply in
            let ok = reply["ok"] as? Bool ?? true
            let reason = ok ? nil : (reply["reason"] as? String ?? "L'iPhone a refusé le départ.")
            Task { @MainActor in completion(reason) }
        }, errorHandler: { _ in
            Task { @MainActor in completion(unreachable) }
        })
    }

    private func ingestMirror(_ dict: [String: Any]) {
        guard let data = dict[WCKeys.coachState] as? Data,
              let mirror = try? WCCodec.decoder.decode(CoachMirror.self, from: data) else { return }
        Task { @MainActor in
            guard WatchMirror.shared.state.timestamp <= mirror.timestamp else { return }
            let wasLive = WatchMirror.shared.state.phase != "idle"
            WatchMirror.shared.state = mirror
            // L'iPhone dit que la séance est finie : la montre arrête sa capture même si la commande « terminer »
            // s'est perdue (iPhone verrouillé ou app suspendue au moment de l'envoi). Séance du 22/09.
            if wasLive, mirror.phase == "idle", WorkoutManager.shared.isActive {
                WorkoutManager.shared.end()
            }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in WatchMirror.shared.phoneReachable = session.isReachable }
        if !session.receivedApplicationContext.isEmpty {
            ingestMirror(session.receivedApplicationContext)
            handleContextCommand(session.receivedApplicationContext)
        }
    }

    /// Commande déposée dans le contexte (montre injoignable au moment de l'envoi) : même chemin que les messages,
    /// la déduplication est faite une seule fois dans `handleCommand`.
    private func handleContextCommand(_ dict: [String: Any]) {
        handleCommand(in: dict)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in WatchMirror.shared.phoneReachable = session.isReachable }
    }

    /// Sondes de portée de l'iPhone : rien à faire, la livraison seule compte (confirmée côté iPhone).
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if userInfo[WCKeys.probe] != nil { return }
        ingestMirror(userInfo)
        handleCommand(in: userInfo)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        ingestMirror(applicationContext)
        handleContextCommand(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        ingestMirror(message)
        handleCommand(in: message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleCommand(in: message)
        replyHandler(["ok": true])
    }

    /// Une commande arrive souvent deux fois (message direct + contexte applicatif) : l'horodatage de l'iPhone sert
    /// à ne l'exécuter qu'une seule fois. Sans ça, un « démarrer » en double relançait puis arrêtait la séance.
    private func handleCommand(in message: [String: Any]) {
        guard let data = message[WCKeys.command] as? Data,
              let payload = try? WCCodec.decoder.decode(WatchCommandPayload.self, from: data) else { return }
        if let at = message[WCKeys.commandAt] as? Double {
            guard at > lastHandledCommandAt, Date().timeIntervalSince1970 - at < 600 else { return }
            lastHandledCommandAt = at
        }
        Task { @MainActor in
            WorkoutManager.shared.handle(command: payload)
        }
    }
}
