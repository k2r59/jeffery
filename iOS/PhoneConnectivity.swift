import Foundation
import WatchConnectivity
import os
import HealthKit

/// Côté iPhone : réception des métriques de la montre, envoi de commandes, lancement de l'app montre.
final class PhoneConnectivity: NSObject, ObservableObject {
    @Published private(set) var latest: MetricsSnapshot?
    @Published private(set) var isReachable = false
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    /// Dernier signe de vie de l'app montre (ping quand elle est ouverte, ou instantané de séance).
    @Published private(set) var lastWatchSeenAt: Date = .distantPast

    /// Source de vérité unique « montre connectée » : la montre est à portée, app ouverte ou endormie (écran éteint).
    /// App éveillée : joignable au sens d'Apple, ou ping/instantané depuis moins de 20 s. App endormie : une sonde
    /// transferUserInfo livrée depuis moins de 45 s (livraison confirmée dès que le paquet atteint la montre). Au départ,
    /// l'iPhone réveille l'app montre (startWatchApp). Tant que l'iPhone n'affiche pas « Montre connectée », ni lui ni la
    /// montre ne peuvent démarrer une séance.
    @Published private(set) var watchConnected = false
    private static let heartbeatGrace: TimeInterval = 20
    private static let rangeGrace: TimeInterval = 45
    private static let probeInterval: TimeInterval = 15
    private var connectionTimer: Timer?
    /// Dernière livraison confirmée d'une sonde (montre à portée).
    @Published private(set) var lastInRangeAt: Date = .distantPast
    private var probe: WCSessionUserInfoTransfer?
    private var lastProbeAt: Date = .distantPast
    private var probesConfirmed = 0
    private let logger = Logger(subsystem: "dev.promo.watchcoach", category: "watch")
    @Published private(set) var activationState = "non activée"
    @Published private(set) var pingsReceived = 0
    /// Bat toutes les 2 s pour que « signe de vie il y a N s » se rafraîchisse à l'écran.
    @Published private(set) var heartbeatTick = 0

    /// Ligne de diagnostic (administrateur) : les drapeaux bruts derrière « Montre connectée ».
    var diagnostic: String {
        func ago(_ d: Date) -> String { d == .distantPast ? "jamais" : "il y a \(Int(Date().timeIntervalSince(d))) s" }
        return "session \(activationState) · jumelée \(isPaired ? "✓" : "✗") · app \(isWatchAppInstalled ? "✓" : "✗") · joignable \(isReachable ? "✓" : "✗") · signe de vie \(ago(lastWatchSeenAt)) · pings \(pingsReceived) · à portée \(ago(lastInRangeAt)) · sondes \(probesConfirmed)\(probe?.isTransferring == true ? " (une en vol)" : "")"
    }
    /// L'app montre est éveillée (elle répondra tout de suite) ; sinon, à portée mais endormie, l'iPhone la réveille.
    var watchAppAwake: Bool { isReachable || Date().timeIntervalSince(lastWatchSeenAt) < Self.heartbeatGrace }

    var linkLabel: String { watchConnected ? "Montre connectée" : "Montre déconnectée" }
    /// Ce qu'il faut faire pour que la montre passe « connectée ».
    var disconnectedHint: String {
        if !isPaired { return "Aucune Apple Watch jumelée à cet iPhone." }
        if !isWatchAppInstalled { return "Installe Jeffrey sur ta montre pour démarrer." }
        return "Montre hors de portée : rapproche-la de l'iPhone."
    }

    var onSnapshot: ((MetricsSnapshot) -> Void)?
    /// Demandes venant de la montre (démarrer, pause, reprendre, terminer la séance iPhone).
    /// Retourne la raison du refus, ou nil si la demande est acceptée ; la montre l'affiche.
    var onWatchRequest: ((WatchCommandPayload) -> String?)?

    private func markSeen(ping: Bool = false) {
        lastWatchSeenAt = Date()
        if ping { pingsReceived += 1 }
        refreshConnected()
    }

    /// Montre à portée Bluetooth (sonde livrée récemment), que l'app y soit ouverte ou non.
    var watchInRange: Bool { watchAppAwake || Date().timeIntervalSince(lastInRangeAt) < Self.rangeGrace }

    private func refreshConnected() {
        let now = watchInRange
        if now != watchConnected {
            watchConnected = now
            logger.notice("montre \(now ? "connectée" : "déconnectée", privacy: .public) — \(self.diagnostic, privacy: .public)")
        }
    }

    private func startConnectionTimer() {
        guard connectionTimer == nil else { return }
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.probeRangeIfNeeded()
            self?.refreshConnected()
            self?.heartbeatTick &+= 1
        }
    }

    /// Sonde de portée : une à la fois, toutes les 15 s, même app montre ouverte, pour que la portée soit déjà connue
    /// quand l'écran de la montre s'éteint. Une sonde en attente reste valable : si la montre revient à portée, sa
    /// livraison le signalera.
    private func probeRangeIfNeeded() {
        guard isPaired, isWatchAppInstalled else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if let probe, probe.isTransferring { return }
        guard Date().timeIntervalSince(lastProbeAt) >= Self.probeInterval else { return }
        lastProbeAt = Date()
        probe = session.transferUserInfo([WCKeys.probe: Date().timeIntervalSince1970])
    }
    /// Les instantanés antérieurs à cette date sont ignorés (reliquats d'une séance précédente).
    var acceptSnapshotsSince: Date = .distantPast

    /// Oublie l'instantané de la séance précédente.
    func reset() {
        latest = nil
    }

    #if DEBUG
    private var fakeWatch: FakeWatch?
    /// Banc d'essai : instantané injecté comme s'il venait de la montre.
    func debugInject(_ snap: MetricsSnapshot) {
        if snap.timestamp < acceptSnapshotsSince { return }
        latest = snap
        onSnapshot?(snap)
    }
    #endif

    private let healthStore = HKHealthStore()
    /// Contexte applicatif fusionné : commande en attente + état miroir (updateApplicationContext remplace tout).
    private var context: [String: Any] = [:]

    private func pushContext() {
        try? WCSession.default.updateApplicationContext(context)
    }

    func activate() {
        #if DEBUG
        if FakeWatch.enabled {
            fakeWatch = FakeWatch(connectivity: self)
            isPaired = true; isWatchAppInstalled = true; isReachable = true; watchConnected = true
            return
        }
        // Tests d'interface « sans montre » : WatchConnectivity n'est pas activée, même si une montre simulée est jumelée.
        if ProcessInfo.processInfo.environment["WATCHCOACH_NO_WATCH"] == "1" { return }
        #endif
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        startConnectionTimer()
    }

    func requestHealthAuthorization() {
        guard HKHealthStore.isHealthDataAvailable(), ProcessInfo.processInfo.environment["WATCHCOACH_NO_HEALTH"] == nil else { return }
        var types: Set<HKObjectType> = [HKObjectType.workoutType(), HKQuantityType(.heartRate),
                                        HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceWalkingRunning)]
        types.formUnion(HealthProfile.readTypes)
        healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: types) { _, _ in }
    }

    /// Lance l'app montre avec une configuration de séance (mode piloté). La montre démarre la HKWorkoutSession.
    func launchWatchWorkout(kind: WorkoutKind, completion: @escaping (Error?) -> Void) {
        #if DEBUG
        if let fake = fakeWatch { Task { @MainActor in fake.handle(command: .start, kind: kind); completion(nil) }; return }
        #endif
        let config = HKWorkoutConfiguration()
        config.activityType = kind.activityType
        config.locationType = kind.locationType
        healthStore.startWatchApp(with: config) { success, error in
            DispatchQueue.main.async {
                completion(success ? nil : (error ?? NSError(domain: "WatchCoach", code: 2,
                                                              userInfo: [NSLocalizedDescriptionKey: "Lancement montre refusé"])))
            }
        }
    }

    func send(command: WatchCommand, kind: WorkoutKind, mode: CaptureMode, completion: ((Error?) -> Void)? = nil) {
        #if DEBUG
        if let fake = fakeWatch {
            Task { @MainActor in fake.handle(command: command, kind: kind); completion?(nil) }
            return
        }
        #endif
        let payload = WatchCommandPayload(command: command, kind: kind, mode: mode)
        guard let data = try? WCCodec.encoder.encode(payload) else { return }
        let session = WCSession.default
        // Horodatage porté par les deux canaux (message et contexte) : la montre n'exécute la commande qu'une fois,
        // même quand les deux la lui livrent.
        let at = Date().timeIntervalSince1970
        context[WCKeys.command] = data
        context[WCKeys.commandAt] = at
        pushContext()
        guard session.activationState == .activated else {
            completion?(NSError(domain: "WatchCoach", code: 3, userInfo: [NSLocalizedDescriptionKey: "WatchConnectivity inactif"]))
            return
        }
        if session.isReachable {
            session.sendMessage([WCKeys.command: data, WCKeys.commandAt: at], replyHandler: { _ in
                DispatchQueue.main.async { completion?(nil) }
            }, errorHandler: { error in
                DispatchQueue.main.async { completion?(error) }
            })
        } else {
            completion?(NSError(domain: "WatchCoach", code: 4,
                                userInfo: [NSLocalizedDescriptionKey: "Montre non joignable : ouvre Jeffrey sur la montre"]))
        }
    }

    /// Envoie l'état de la séance à la montre (message si joignable, contexte applicatif dans tous les cas).
    func sendCoachState(_ mirror: CoachMirror) {
        #if DEBUG
        if fakeWatch != nil { return }
        #endif
        guard WCSession.isSupported(), let data = try? WCCodec.encoder.encode(mirror) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        context[WCKeys.coachState] = data
        pushContext()
        if session.isReachable {
            session.sendMessage([WCKeys.coachState: data], replyHandler: nil, errorHandler: { _ in })
        }
    }

    /// `reply` reçoit la raison d'un refus (nil = accepté) ; il est appelé sur le fil principal, après traitement.
    private func ingest(_ dict: [String: Any], reply: ((String?) -> Void)? = nil) {
        if let data = dict[WCKeys.command] as? Data,
           let payload = try? WCCodec.decoder.decode(WatchCommandPayload.self, from: data) {
            DispatchQueue.main.async {
                self.markSeen()
                let refusal = self.onWatchRequest?(payload)
                reply?(refusal)
            }
            return
        }
        reply?(nil)
        guard let data = dict[WCKeys.metrics] as? Data,
              let snap = try? WCCodec.decoder.decode(MetricsSnapshot.self, from: data) else { return }
        DispatchQueue.main.async {
            // Ignore un instantané plus vieux que le dernier reçu (les files de secours peuvent arriver en retard),
            // ou antérieur au début de la séance en cours.
            if snap.timestamp < self.acceptSnapshotsSince { return }
            if let last = self.latest, last.timestamp > snap.timestamp { return }
            self.markSeen()
            self.latest = snap
            self.onSnapshot?(snap)
        }
    }

    private func refreshFlags(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            switch session.activationState {
            case .activated: self.activationState = "activée"
            case .inactive: self.activationState = "inactive"
            case .notActivated: self.activationState = "non activée"
            @unknown default: self.activationState = "?"
            }
            self.logger.notice("drapeaux : \(self.diagnostic, privacy: .public)")
            self.refreshConnected()
        }
    }
}

extension PhoneConnectivity: WCSessionDelegate {
    /// Livraison d'une sonde confirmée : la montre est à portée (l'app montre n'a pas besoin d'être ouverte).
    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard userInfoTransfer.userInfo[WCKeys.probe] != nil else { return }
        DispatchQueue.main.async {
            if let error {
                self.logger.notice("sonde : \(error.localizedDescription, privacy: .public)")
            } else {
                self.lastInRangeAt = Date()
                self.probesConfirmed += 1
                self.refreshConnected()
            }
            if self.probe === userInfoTransfer { self.probe = nil }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error { logger.error("activation : \(error.localizedDescription, privacy: .public)") }
        refreshFlags(session)
        // Le contexte reçu au lancement est un reliquat : on ne le prend que s'il est frais.
        if let data = session.receivedApplicationContext[WCKeys.metrics] as? Data,
           let snap = try? WCCodec.decoder.decode(MetricsSnapshot.self, from: data),
           Date().timeIntervalSince(snap.timestamp) < 30 {
            ingest(session.receivedApplicationContext)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        refreshFlags(session)
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        refreshFlags(session)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message[WCKeys.ping] != nil { DispatchQueue.main.async { self.markSeen(ping: true) }; return }
        ingest(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if message[WCKeys.ping] != nil { DispatchQueue.main.async { self.markSeen(ping: true) }; replyHandler(["ok": true]); return }
        ingest(message) { refusal in
            if let refusal { replyHandler(["ok": false, "reason": refusal]) } else { replyHandler(["ok": true]) }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        ingest(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        ingest(userInfo)
    }
}
