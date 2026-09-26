import Foundation
import HealthKit
import WatchKit
import Combine
import CoreLocation

/// Gère la capture des métriques côté montre : notre app possède la HKWorkoutSession (séance enregistrée par Jeffrey).
@MainActor
final class WorkoutManager: NSObject, ObservableObject {
    static let shared = WorkoutManager()

    @Published private(set) var snapshot: MetricsSnapshot = .idle(kind: .running)
    @Published private(set) var statusMessage: String = ""
    @Published var selectedKind: WorkoutKind = .running

    private let healthStore = HKHealthStore()

    // Mode owned
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private let locationManager = CLLocationManager()
    private var recordingRoute = false

    private var startDate: Date?
    /// Départ demandé pendant qu'une capture se terminait : rejoué dès qu'elle est close.
    private var pendingStart: WatchCommandPayload?
    /// Instant réel où la capture en cours a commencé (horloge de la montre).
    private var captureBeganAt: Date = .distantPast
    private var pausedAccumulated: TimeInterval = 0
    private var pauseStartedAt: Date?
    private var tickTimer: Timer?
    /// iPhone silencieux (app fermée ou morte) : la montre arrête sa capture d'elle-même passé ce délai.
    private let phoneSilenceLimit: TimeInterval = 5 * 60
    private var lastSendAt: Date = .distantPast

    var isActive: Bool { snapshot.state == .running || snapshot.state == .paused }

    #if DEBUG
    /// Banc d'essai (simulateur) : pas de HealthKit, la montre fabrique elle-même un cœur, une distance et des calories
    /// plausibles et les envoie à l'iPhone par la vraie WatchConnectivity. WATCHCOACH_FAKE_HEALTH=1.
    static let fakeHealth = ProcessInfo.processInfo.environment["WATCHCOACH_FAKE_HEALTH"] == "1"
    private var fakeTimer: Timer?
    private var fakeDistance: Double = 0
    private var fakeEnergy: Double = 0
    #endif

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
        #if DEBUG
        if Self.fakeHealth { standbyActive = true; return }
        #endif
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
        #if DEBUG
        if Self.fakeHealth { return }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.runningSpeed),
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

    func handle(command payload: WatchCommandPayload, issuedAt: Date? = nil) {
        // Le contexte garde la dernière commande : relue au lancement de l'app (départ à distance), elle vise une
        // capture précédente (« terminer » de la séance d'avant, ou le départ qui vient de lancer celle-ci).
        if isActive, let issuedAt, issuedAt <= captureBeganAt { return }
        switch payload.command {
        case .start:
            // Nouveau départ = tout repart de zéro : une capture encore en cours (séance précédente mal close,
            // suivi compagnon oublié) est arrêtée avant, sinon l'iPhone hérite du chrono et des distances d'avant.
            // La fin d'une HKWorkoutSession est asynchrone : le nouveau départ attend qu'elle soit close.
            selectedKind = payload.kind
            if isActive {
                pendingStart = payload
                end()
                return
            }
            startOwned(kind: payload.kind)
        case .pause: pause()
        case .resume: resume()
        case .end: end()
        case .requestStart, .requestPause, .requestResume, .requestEnd, .ask:
            break // demandes montre → iPhone, jamais reçues ici
        }
    }

    // MARK: - Mode owned (HKWorkoutSession)

    func startOwned(kind: WorkoutKind) {
        guard !isActive else { return }
        endStandby()
        #if DEBUG
        if Self.fakeHealth { startFakeOwned(kind: kind); return }
        #endif
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
            beginTracking(kind: kind, start: start)
            if kind.locationType == .outdoor { startRouteRecording() }
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { _, error in
                if let error {
                    Task { @MainActor in self.statusMessage = "Collecte : \(error.localizedDescription)" }
                }
            }
            statusMessage = "Séance Jeffrey en cours"
        } catch {
            statusMessage = "Impossible de démarrer : \(error.localizedDescription)"
        }
    }

    // MARK: - Contrôles communs

    func pause() {
        guard snapshot.state == .running else { return }
        #if DEBUG
        if Self.fakeHealth { markPaused(); return }
        #endif
        session?.pause()
    }

    func resume() {
        guard snapshot.state == .paused else { return }
        #if DEBUG
        if Self.fakeHealth { markResumed(); return }
        #endif
        session?.resume()
    }

    func end() {
        guard isActive else { return }
        #if DEBUG
        if Self.fakeHealth { fakeTimer?.invalidate(); fakeTimer = nil; finishTracking(); return }
        #endif
        session?.end()
    }

    // MARK: - Suivi du temps et publication

    private func beginTracking(kind: WorkoutKind, start: Date) {
        // L'app reste au premier plan bien plus longtemps après le poignet baissé (limite système ~8 min).
        WKExtension.shared().isFrontmostTimeoutExtended = true
        captureBeganAt = Date()
        startDate = start
        pausedAccumulated = 0
        pauseStartedAt = nil
        var snap = MetricsSnapshot.idle(kind: kind)
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
        let elapsed = currentElapsed()
        startDate = nil
        session = nil
        builder = nil
        var snap = snapshot
        snap.state = .ended
        snap.elapsed = elapsed
        snapshot = snap
        publish(snap, force: true)
        // Un départ attendait la fin de la capture précédente (deux séances à la suite) : il part maintenant, à zéro.
        if let next = pendingStart {
            pendingStart = nil
            startOwned(kind: next.kind)
            return
        }
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
        if startDate != nil { s.elapsed = currentElapsed() }
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

// MARK: - GPS (extérieur)

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

#if DEBUG
// MARK: - Source factice (banc d'essai simulateur)

extension WorkoutManager {
    /// Profil de séance plausible : montée en 90 s vers 150 bpm, plateau, pointe à 172 bpm entre 4 et 6 min, puis
    /// endurance ; en pause le cœur redescend. 2,8 m/s en course, kcal cumulées.
    fileprivate func startFakeOwned(kind: WorkoutKind) {
        fakeDistance = 0
        fakeEnergy = 0
        beginTracking(kind: kind, start: Date())
        statusMessage = "Séance factice en cours (banc d'essai)"
        fakeTimer?.invalidate()
        fakeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fakeTick() }
        }
    }

    private func fakeTick() {
        guard isActive else { fakeTimer?.invalidate(); fakeTimer = nil; return }
        let t = currentElapsed()
        var snap = snapshot
        let paused = snapshot.state == .paused
        let target: Double
        switch t {
        case ..<90: target = 110 + 40 * (t / 90)
        case 240..<360: target = 172
        default: target = 150
        }
        let wobble = sin(t / 7) * 3
        snap.heartRate = paused ? max(95, (snap.heartRate ?? 120) - 2) : target + wobble
        if !paused {
            if snapshot.kind.usesDistance { fakeDistance += 2.8 * 2; snap.distance = fakeDistance; snap.speed = 2.8 + sin(t / 11) * 0.3 }
            fakeEnergy += 0.4
            snap.activeEnergy = fakeEnergy
        }
        snap.lastSampleAt = Date()
        publish(snap, force: true)
    }
}
#endif
