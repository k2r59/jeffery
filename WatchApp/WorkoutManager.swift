import Foundation
import HealthKit
import WatchKit
import Combine

/// Gère la capture des métriques côté montre, dans l'un des deux modes :
/// - `owned` : notre app possède la HKWorkoutSession (séance enregistrée par WatchCoach).
/// - `companion` : l'app Exercice native possède la séance ; on garde de l'exécution en arrière-plan
///   via une WKExtendedRuntimeSession et on lit les échantillons HealthKit au fil de l'eau.
@MainActor
final class WorkoutManager: NSObject, ObservableObject {
    static let shared = WorkoutManager()

    @Published private(set) var snapshot: MetricsSnapshot = .idle(kind: .running, mode: .owned)
    @Published private(set) var statusMessage: String = ""
    @Published var selectedKind: WorkoutKind = .running

    private let healthStore = HKHealthStore()

    // Mode owned
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    // Mode companion
    private var runtimeSession: WKExtendedRuntimeSession?
    private var queries: [HKQuery] = []
    private var companionEnergy: Double = 0
    private var companionDistance: Double = 0
    private var seenSampleUUIDs = Set<UUID>()

    private var startDate: Date?
    private var pausedAccumulated: TimeInterval = 0
    private var pauseStartedAt: Date?
    private var tickTimer: Timer?
    private var lastSendAt: Date = .distantPast

    var isActive: Bool { snapshot.state == .running || snapshot.state == .paused }

    // MARK: - Autorisation

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.runningSpeed),
            HKObjectType.workoutType(),
        ]
        let share: Set<HKSampleType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKObjectType.workoutType(),
        ]
        healthStore.requestAuthorization(toShare: share, read: read) { _, error in
            if let error {
                Task { @MainActor in self.statusMessage = "HealthKit : \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Commandes venant de l'iPhone

    func handle(command payload: WatchCommandPayload) {
        switch payload.command {
        case .start:
            guard !isActive else { return }
            selectedKind = payload.kind
            payload.mode == .owned ? startOwned(kind: payload.kind) : startCompanion(kind: payload.kind)
        case .pause: pause()
        case .resume: resume()
        case .end: end()
        }
    }

    // MARK: - Mode owned (HKWorkoutSession)

    func startOwned(kind: WorkoutKind) {
        guard !isActive else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = kind.activityType
        config.locationType = kind.locationType
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            let start = Date()
            beginTracking(kind: kind, mode: .owned, start: start)
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { _, error in
                if let error {
                    Task { @MainActor in self.statusMessage = "Collecte : \(error.localizedDescription)" }
                }
            }
            statusMessage = "Séance WatchCoach en cours"
        } catch {
            statusMessage = "Impossible de démarrer : \(error.localizedDescription)"
        }
    }

    // MARK: - Mode companion (app Exercice native + lecture HealthKit)

    func startCompanion(kind: WorkoutKind) {
        guard !isActive else { return }
        let start = Date()
        companionEnergy = 0
        companionDistance = 0
        seenSampleUUIDs.removeAll()
        beginTracking(kind: kind, mode: .companion, start: start)

        // Exécution en arrière-plan (max ~1 h par session, relance depuis l'app si besoin).
        let runtime = WKExtendedRuntimeSession()
        runtime.delegate = self
        runtime.start()
        runtimeSession = runtime

        let predicate = HKQuery.predicateForSamples(withStart: start.addingTimeInterval(-5), end: nil, options: [])
        var types: [HKQuantityType] = [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned), HKQuantityType(.runningSpeed)]
        if let d = kind.distanceType { types.append(d) }
        for type in types {
            let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit) { [weak self] _, samples, _, _, _ in
                self?.ingest(type: type, samples: samples)
            }
            query.updateHandler = { [weak self] _, samples, _, _, _ in
                self?.ingest(type: type, samples: samples)
            }
            healthStore.execute(query)
            queries.append(query)
        }
        statusMessage = "Suit l'app Exercice (lance ta séance native si ce n'est pas fait)"
    }

    nonisolated private func ingest(type: HKQuantityType, samples: [HKSample]?) {
        guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else { return }
        Task { @MainActor in
            let fresh = samples.filter { !self.seenSampleUUIDs.contains($0.uuid) }
            guard !fresh.isEmpty else { return }
            fresh.forEach { self.seenSampleUUIDs.insert($0.uuid) }
            let latest = fresh.max { $0.startDate < $1.startDate }
            var snap = self.snapshot
            switch type {
            case HKQuantityType(.heartRate):
                if let latest {
                    snap.heartRate = latest.quantity.doubleValue(for: .count().unitDivided(by: .minute()))
                }
            case HKQuantityType(.activeEnergyBurned):
                self.companionEnergy += fresh.reduce(0) { $0 + $1.quantity.doubleValue(for: .kilocalorie()) }
                snap.activeEnergy = self.companionEnergy
            case HKQuantityType(.runningSpeed):
                if let latest {
                    snap.speed = latest.quantity.doubleValue(for: .meter().unitDivided(by: .second()))
                }
            default:
                // distance (marche/course ou vélo)
                self.companionDistance += fresh.reduce(0) { $0 + $1.quantity.doubleValue(for: .meter()) }
                snap.distance = self.companionDistance
            }
            snap.lastSampleAt = latest?.endDate ?? Date()
            self.publish(snap)
        }
    }

    // MARK: - Contrôles communs

    func pause() {
        guard snapshot.state == .running else { return }
        if snapshot.mode == .owned {
            session?.pause()
        } else {
            markPaused()
        }
    }

    func resume() {
        guard snapshot.state == .paused else { return }
        if snapshot.mode == .owned {
            session?.resume()
        } else {
            markResumed()
        }
    }

    func end() {
        guard isActive else { return }
        if snapshot.mode == .owned {
            session?.end()
        } else {
            stopCompanion()
        }
    }

    private func stopCompanion() {
        queries.forEach { healthStore.stop($0) }
        queries.removeAll()
        runtimeSession?.invalidate()
        runtimeSession = nil
        finishTracking()
        statusMessage = "Suivi arrêté"
    }

    // MARK: - Suivi du temps et publication

    private func beginTracking(kind: WorkoutKind, mode: CaptureMode, start: Date) {
        startDate = start
        pausedAccumulated = 0
        pauseStartedAt = nil
        var snap = MetricsSnapshot.idle(kind: kind, mode: mode)
        snap.state = .running
        snapshot = snap
        publish(snap, force: true)
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.publish(self.snapshot, force: true)
            }
        }
    }

    private func finishTracking() {
        tickTimer?.invalidate()
        tickTimer = nil
        var snap = snapshot
        snap.state = .ended
        snap.elapsed = currentElapsed()
        snapshot = snap
        publish(snap, force: true)
        startDate = nil
        session = nil
        builder = nil
    }

    private func markPaused() {
        pauseStartedAt = Date()
        var snap = snapshot
        snap.state = .paused
        publish(snap, force: true)
    }

    private func markResumed() {
        if let p = pauseStartedAt { pausedAccumulated += Date().timeIntervalSince(p) }
        pauseStartedAt = nil
        var snap = snapshot
        snap.state = .running
        publish(snap, force: true)
    }

    private func currentElapsed() -> TimeInterval {
        guard let startDate else { return 0 }
        var elapsed = Date().timeIntervalSince(startDate) - pausedAccumulated
        if let p = pauseStartedAt { elapsed -= Date().timeIntervalSince(p) }
        return max(0, elapsed)
    }

    /// Met à jour l'état local et envoie à l'iPhone (au plus une fois par seconde sauf `force`).
    private func publish(_ snap: MetricsSnapshot, force: Bool = false) {
        var s = snap
        s.timestamp = Date()
        s.elapsed = currentElapsed()
        snapshot = s
        let now = Date()
        guard force || now.timeIntervalSince(lastSendAt) >= 1 else { return }
        lastSendAt = now
        WatchSender.shared.send(s)
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            switch toState {
            case .running:
                if self.snapshot.state == .paused { self.markResumed() }
            case .paused:
                self.markPaused()
            case .ended:
                guard let builder = self.builder else { self.finishTracking(); return }
                builder.endCollection(withEnd: date) { _, _ in
                    builder.finishWorkout { _, error in
                        Task { @MainActor in
                            if let error { self.statusMessage = "Enregistrement : \(error.localizedDescription)" }
                            else { self.statusMessage = "Séance enregistrée dans Santé" }
                            self.finishTracking()
                        }
                    }
                }
            default:
                break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.statusMessage = "Séance : \(error.localizedDescription)"
            self.finishTracking()
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor in
            var snap = self.snapshot
            for case let type as HKQuantityType in collectedTypes {
                guard let stats = workoutBuilder.statistics(for: type) else { continue }
                switch type {
                case HKQuantityType(.heartRate):
                    snap.heartRate = stats.mostRecentQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
                case HKQuantityType(.activeEnergyBurned):
                    snap.activeEnergy = stats.sumQuantity()?.doubleValue(for: .kilocalorie())
                case HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling):
                    snap.distance = stats.sumQuantity()?.doubleValue(for: .meter())
                case HKQuantityType(.runningSpeed):
                    snap.speed = stats.mostRecentQuantity()?.doubleValue(for: .meter().unitDivided(by: .second()))
                default:
                    continue
                }
            }
            snap.lastSampleAt = Date()
            self.publish(snap)
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - WKExtendedRuntimeSessionDelegate (mode companion)

extension WorkoutManager: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in self.statusMessage = "Suivi en arrière-plan actif" }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            WKInterfaceDevice.current().play(.notification)
            self.statusMessage = "Arrière-plan bientôt expiré : rouvre WatchCoach pour prolonger"
        }
    }

    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        Task { @MainActor in
            guard self.snapshot.mode == .companion, self.isActive else { return }
            self.runtimeSession = nil
            switch reason {
            case .sessionInProgress, .expired, .resignedFrontmost:
                self.statusMessage = "Arrière-plan interrompu (\(reason.rawValue)) : touche « Prolonger »"
            default:
                self.statusMessage = "Arrière-plan interrompu : \(error?.localizedDescription ?? "raison \(reason.rawValue)")"
            }
        }
    }

    /// Relance la session d'exécution étendue (l'app doit être au premier plan).
    func extendBackground() {
        guard snapshot.mode == .companion, isActive, runtimeSession == nil else { return }
        let runtime = WKExtendedRuntimeSession()
        runtime.delegate = self
        runtime.start()
        runtimeSession = runtime
    }

    var needsBackgroundExtension: Bool {
        snapshot.mode == .companion && isActive && runtimeSession == nil
    }
}
