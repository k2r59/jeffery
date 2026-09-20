import Foundation
import WatchConnectivity
import HealthKit

/// Côté iPhone : réception des métriques de la montre, envoi de commandes, lancement de l'app montre.
final class PhoneConnectivity: NSObject, ObservableObject {
    @Published private(set) var latest: MetricsSnapshot?
    @Published private(set) var isReachable = false
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    /// Dernier signe de vie de l'app montre (ping quand elle est ouverte, ou instantané de séance).
    @Published private(set) var lastWatchSeenAt: Date = .distantPast

    enum LinkState { case connected, paired, unpaired }
    /// État tel que l'utilisateur le comprend : « joignable » au sens d'Apple veut dire app montre au premier plan ;
    /// dès que le poignet baisse elle s'endort. On garde « connectée » 20 s après le dernier signe de vie.
    var linkState: LinkState {
        if isReachable || Date().timeIntervalSince(lastWatchSeenAt) < 20 { return .connected }
        return isPaired && isWatchAppInstalled ? .paired : .unpaired
    }
    var linkLabel: String {
        switch linkState {
        case .connected: return "Connectée"
        case .paired: return "Jumelée · app montre en veille"
        case .unpaired: return isPaired ? "App montre non installée" : "Non jumelée"
        }
    }

    var onSnapshot: ((MetricsSnapshot) -> Void)?
    /// Demandes venant de la montre (démarrer, pause, reprendre, terminer la séance iPhone).
    var onWatchRequest: ((WatchCommandPayload) -> Void)?
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
            isPaired = true; isWatchAppInstalled = true; isReachable = true
            return
        }
        #endif
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
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
        context[WCKeys.command] = data
        context[WCKeys.commandAt] = Date().timeIntervalSince1970
        pushContext()
        guard session.activationState == .activated else {
            completion?(NSError(domain: "WatchCoach", code: 3, userInfo: [NSLocalizedDescriptionKey: "WatchConnectivity inactif"]))
            return
        }
        if session.isReachable {
            session.sendMessage([WCKeys.command: data], replyHandler: { _ in
                DispatchQueue.main.async { completion?(nil) }
            }, errorHandler: { error in
                DispatchQueue.main.async { completion?(error) }
            })
        } else {
            completion?(NSError(domain: "WatchCoach", code: 4,
                                userInfo: [NSLocalizedDescriptionKey: "Montre non joignable : ouvre WatchCoach sur la montre"]))
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

    private func ingest(_ dict: [String: Any]) {
        if let data = dict[WCKeys.command] as? Data,
           let payload = try? WCCodec.decoder.decode(WatchCommandPayload.self, from: data) {
            DispatchQueue.main.async { self.onWatchRequest?(payload) }
            return
        }
        guard let data = dict[WCKeys.metrics] as? Data,
              let snap = try? WCCodec.decoder.decode(MetricsSnapshot.self, from: data) else { return }
        DispatchQueue.main.async {
            // Ignore un instantané plus vieux que le dernier reçu (les files de secours peuvent arriver en retard),
            // ou antérieur au début de la séance en cours.
            if snap.timestamp < self.acceptSnapshotsSince { return }
            if let last = self.latest, last.timestamp > snap.timestamp { return }
            self.lastWatchSeenAt = Date()
            self.latest = snap
            self.onSnapshot?(snap)
        }
    }

    private func refreshFlags(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
        }
    }
}

extension PhoneConnectivity: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
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
        if message[WCKeys.ping] != nil { DispatchQueue.main.async { self.lastWatchSeenAt = Date() }; return }
        ingest(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if message[WCKeys.ping] != nil { DispatchQueue.main.async { self.lastWatchSeenAt = Date() }; replyHandler(["ok": true]); return }
        ingest(message)
        replyHandler(["ok": true])
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        ingest(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        ingest(userInfo)
    }
}
