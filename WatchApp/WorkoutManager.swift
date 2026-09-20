import Foundation
import HealthKit
import WatchKit
import Combine
import CoreLocation

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
    private var routeBuilder: HKWorkoutRouteBuilder?
    private let locationManager = CLLocationManager()
    private var recordingRoute = false

    // Mode companion
    private var runtimeSession: WKExtendedRuntimeSession?
    private var queries: [HKQuery] = []
    private var companionEnergy: Double = 0
    private var companionDistance: Double = 0
    private var seenSampleUUIDs = Set<UUID>()

    private var startDate: Date?
    private var companionGeneration = 0
    private var pausedAccumulated: TimeInterval = 0
    private var pauseStartedAt: Date?
    private var tickTimer: Timer?
    /// iPhone silencieux (app fermée ou morte) : la montre arrête sa capture d'elle-même passé ce délai.
    private let phoneSilenceLimit: TimeInterval = 5 * 60
    private var lastSendAt: Date = .distantPast

    var isActive: Bool { snapshot.state == .running || snapshot.state == .paused }

    // MARK: - Veille active (app ouverte, écran éteint)

    /// Écran éteint, watchOS suspend l'app : plus de ping, iPhone « montre déconnectée ». Une session HealthKit
    /// simplement *préparée* (mode session, sans enregistrement) garde l'app éveillée : elle continue de pinger et de
    /// répondre à l'iPhone. Coupée après 15 min sans départ pour ménager la batterie ; relancée à chaque réveil de l'app.
    private var standbySession: HKWorkoutSession?
    private var standbyTimer: Timer?
    private static let standbyDuration: TimeInterval = 15 * 60
    @Published private(set) var standbyActive = false

    func armStandby() {
        guard !isActive else { return }
        scheduleStandbyTimeout()
        guard standbySession == nil else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = selectedKind.activityType
        config.locationType = selectedKind.locationType
        guard let session = try? HKWorkoutSession(healthStore: healthStore, configuration: config) else { return }
        session.delegate = self
        standbySession = session
        session.prepare()
        standbyActive = true
    }

    func endStandby() {
        standbyTimer?.invalidate(); standbyTimer = nil
        standbyActive = false
        guard let session = standbySession else { return }
        standbySession = nil
        session.end()
    }

    private func scheduleStandbyTimeout() {
        standbyTimer?.invalidate()
        standbyTimer = Timer.scheduledTimer(withTimeInterval: Self.standbyDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endStandby() }
        }
    }

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
        locationManager.delegate = self
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - Commandes venant de l'iPhone

    func handle(command payload: WatchCommandPayload) {
        switch payload.command {
        case .start:
            if isActive {
                // Une séance pilotée ne peut pas être remplacée ; un suivi compagnon oublié, si.
                guard snapshot.mode == .companion else { return }
                stopCompanion()
            }
            selectedKind = payload.kind
            payload.mode == .owned ? startOwned(kind: payload.kind) : startCompanion(kind: payload.kind)
        case .pause: pause()
        case .resume: resume()
        case .end: end()
        case .requestStart, .requestPause, .requestResume, .requestEnd:
            break // demandes montre → iPhone, jamais reçues ici
        }
    }

    // MARK: - Mode owned (HKWorkoutSession)

    func startOwned(kind: WorkoutKind) {
        guard !isActive else { return }
        endStandby()
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
            if kind.locationType == .outdoor { startRouteRecording() }
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
        endStandby()
        companionGeneration += 1
        let generation = companionGeneration
        statusMessage = "Recherche de la séance en cours…"
        Task {
            let inferred = await inferNativeWorkoutStart()
            await MainActor.run {
                guard generation == self.companionGeneration else { return } // un .end est arrivé entre-temps
                self.beginCompanion(kind: kind, start: inferred ?? Date(), inferred: inferred != nil)
            }
        }
    }

    /// L'app Exercice écrit la fréquence cardiaque toutes les quelques secondes pendant une séance, contre
    /// quelques fois par heure au repos : le début de la série dense la plus récente donne le départ de la séance native.
    private func inferNativeWorkoutStart() async -> Date? {
        let type = HKQuantityType(.heartRate)
        let since = Date().addingTimeInterval(-3 * 3600)
        let samples: [HKQuantitySample] = await withCheckedContinuation { c in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForSamples(withStart: since, end: nil, options: []),
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, s, _ in
                c.resume(returning: (s as? [HKQuantitySample]) ?? [])
            }
            healthStore.execute(q)
        }
        guard let last = samples.last, Date().timeIntervalSince(last.startDate) < 90 else { return nil }
        var runStart = last.startDate
        var count = 1
        for i in stride(from: samples.count - 2, through: 0, by: -1) {
            let gap = samples[i + 1].startDate.timeIntervalSince(samples[i].startDate)
            if gap > 30 { break }
            runStart = samples[i].startDate
            count += 1
        }
        return count >= 6 ? runStart : nil
    }

    private func beginCompanion(kind: WorkoutKind, start: Date, inferred: Bool) {
        guard !isActive else { return }
        companionEnergy = 0
        companionDistance = 0
        seenSampleUUIDs.removeAll()
        beginTracking(kind: kind, mode: .companion, start: start)

        // Exécution en arrière-plan (max ~1 h par session, relance depuis l'app si besoin).
        let runtime = WKExtendedRuntimeSession()
        runtime.delegate = self
        runtime.start()
        runtimeSession = runtime

        // Échantillons de la montre uniquement : les pas comptés par l'iPhone ne doivent pas s'ajouter.
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start.addingTimeInterval(-5), end: nil, options: []),
            HKQuery.predicateForObjects(from: Set([HKDevice.local()])),
        ])
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
        // Fin de la séance native : l'app Exercice enregistre alors la séance dans Santé → on arrête de suivre.
        let workoutPredicate = HKQuery.predicateForSamples(withStart: start.addingTimeInterval(-60), end: nil, options: [])
        let workoutQuery = HKAnchoredObjectQuery(type: .workoutType(), predicate: workoutPredicate, anchor: nil, limit: HKObjectQueryNoLimit) { _, _, _, _, _ in }
        workoutQuery.updateHandler = { [weak self] _, samples, _, _, _ in
            guard let workouts = samples as? [HKWorkout], workouts.contains(where: { $0.endDate > start }) else { return }
            Task { @MainActor in
                guard let self, self.isActive, self.snapshot.mode == .companion else { return }
                self.statusMessage = "Séance de l'app Exercice terminée"
                self.stopCompanion()
            }
        }
        healthStore.execute(workoutQuery)
        queries.append(workoutQuery)
        statusMessage = inferred ? "Calé sur la séance en cours" : "Suit l'app Exercice (lance ta séance native si ce n'est pas fait)"
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
        companionGeneration += 1
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
        // L'app reste au premier plan bien plus longtemps après le poignet baissé (limite système ~8 min).
        WKExtension.shared().isFrontmostTimeoutExtended = true
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
                // Plus aucun miroir de l'iPhone depuis 5 min alors qu'il était en séance : l'app a été fermée ou est morte,
                // on n'enregistre pas une séance fantôme sans Jeffrey.
                let m = WatchMirror.shared.state
                if m.phase != "idle", Date().timeIntervalSince(m.timestamp) > self.phoneSilenceLimit {
                    self.statusMessage = "iPhone silencieux depuis 5 min : séance arrêtée."
                    WatchMirror.shared.state = .idle
                    self.end()
                }
            }
        }
    }

    private func finishTracking() {
        WKExtension.shared().isFrontmostTimeoutExtended = false
        stopRouteRecording()
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
        // Séance finie, l'app reste sous les yeux : on la garde éveillée pour la suivante.
        armStandby()
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
        s.sessionStart = startDate
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
            // Seule la session de la séance compte : celle de veille (préparée puis terminée) ne pilote rien.
            guard workoutSession === self.session else { return }
            switch toState {
            case .running:
                if self.snapshot.state == .paused { self.markResumed() }
            case .paused:
                self.markPaused()
            case .ended:
                guard let builder = self.builder else { self.finishTracking(); return }
                let routeBuilder = self.routeBuilder
                let hadRoute = self.recordingRoute
                self.stopRouteRecording()
                builder.endCollection(withEnd: date) { _, _ in
                    builder.finishWorkout { workout, error in
                        // Le tracé GPS est rattaché à la séance une fois celle-ci enregistrée.
                        if let workout, let routeBuilder, hadRoute {
                            routeBuilder.finishRoute(with: workout, metadata: nil) { _, _ in }
                        }
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
            if workoutSession === self.standbySession {
                self.standbySession = nil
                self.standbyActive = false
                return
            }
            guard workoutSession === self.session else { return }
            self.statusMessage = "Séance : \(error.localizedDescription)"
            self.finishTracking()
        }
    }
}

// MARK: - GPS (mode piloté, extérieur)

extension WorkoutManager: CLLocationManagerDelegate {
    private func startRouteRecording() {
        guard locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways else {
            statusMessage = "GPS non autorisé : séance sans tracé"
            return
        }
        routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: nil)
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.startUpdatingLocation()
        recordingRoute = true
    }

    private func stopRouteRecording() {
        guard recordingRoute else { return }
        locationManager.stopUpdatingLocation()
        recordingRoute = false
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let good = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50 }
        guard !good.isEmpty else { return }
        Task { @MainActor in
            guard self.recordingRoute, let routeBuilder = self.routeBuilder else { return }
            routeBuilder.insertRouteData(good) { _, _ in }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
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

    /// Au retour au premier plan : si la session étendue est tombée, on la relance sans rien demander.
    func appBecameActive() {
        if needsBackgroundExtension { extendBackground() }
        armStandby()
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
