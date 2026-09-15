import Foundation
import WatchConnectivity
import HealthKit

/// Côté iPhone : réception des métriques de la montre, envoi de commandes, lancement de l'app montre.
final class PhoneConnectivity: NSObject, ObservableObject {
    @Published private(set) var latest: MetricsSnapshot?
    @Published private(set) var isReachable = false
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false

    var onSnapshot: ((MetricsSnapshot) -> Void)?

    private let healthStore = HKHealthStore()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func requestHealthAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        var types: Set<HKObjectType> = [HKObjectType.workoutType(), HKQuantityType(.heartRate),
                                        HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceWalkingRunning)]
        types.formUnion(HealthProfile.readTypes)
        healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: types) { _, _ in }
    }

    /// Lance l'app montre avec une configuration de séance (mode piloté). La montre démarre la HKWorkoutSession.
    func launchWatchWorkout(kind: WorkoutKind, completion: @escaping (Error?) -> Void) {
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
        let payload = WatchCommandPayload(command: command, kind: kind, mode: mode)
        guard let data = try? WCCodec.encoder.encode(payload) else { return }
        let session = WCSession.default
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

    private func ingest(_ dict: [String: Any]) {
        guard let data = dict[WCKeys.metrics] as? Data,
              let snap = try? WCCodec.decoder.decode(MetricsSnapshot.self, from: data) else { return }
        DispatchQueue.main.async {
            // Ignore un instantané plus vieux que le dernier reçu (les files de secours peuvent arriver en retard).
            if let last = self.latest, last.timestamp > snap.timestamp { return }
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
        if !session.receivedApplicationContext.isEmpty { ingest(session.receivedApplicationContext) }
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
        ingest(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        ingest(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        ingest(userInfo)
    }
}
