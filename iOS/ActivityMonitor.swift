import Foundation
import CoreMotion
import Combine

/// Ce que fait le corps (arrêt, marche, course, vélo) et ce que fait le terrain (plat, montée, descente),
/// à partir du mouvement, de la cadence et du baromètre de l'iPhone. Les changements sont lissés avant d'être annoncés.
@MainActor
final class ActivityMonitor: ObservableObject {
    enum Activity: String { case unknown, stationary, walking, running, cycling
        var label: String {
            switch self {
            case .unknown: return "inconnue"
            case .stationary: return "à l'arrêt"
            case .walking: return "marche"
            case .running: return "course"
            case .cycling: return "vélo"
            }
        }
    }
    enum Terrain: String { case flat, climb, descent
        var label: String {
            switch self {
            case .flat: return "plat"
            case .climb: return "montée"
            case .descent: return "descente"
            }
        }
    }
    enum Event: Equatable {
        case activity(from: Activity, to: Activity)
        case terrain(from: Terrain, to: Terrain)
        case stationaryLong(seconds: Int)
    }

    @Published private(set) var activity: Activity = .unknown
    @Published private(set) var activitySince: Date = Date()
    @Published private(set) var cadence: Double?            // pas / min
    @Published private(set) var terrain: Terrain = .flat
    @Published private(set) var terrainSince: Date = Date()
    @Published private(set) var grade: Double?              // % sur les 100 derniers mètres
    @Published private(set) var ascent: Double = 0          // D+ cumulé (m)
    @Published private(set) var descent: Double = 0         // D- cumulé (m)
    /// Séance en pause : les détections et compteurs sont gelés.
    var paused = false
    /// Cadence de course habituelle de ce coureur (médiane glissante), pour juger une chute de cadence.
    private(set) var typicalRunningCadence: Double = 160
    private var runningCadences: [Double] = []

    var onEvent: ((Event) -> Void)?
    /// Journal des transitions (même sans intervention), pour relecture après la séance.
    var onLog: ((String) -> Void)?
    /// Battement d'une seconde, pendant la séance (le minuteur interne existe déjà).
    var onTick: (() -> Void)?
    /// Distance parcourue fournie par l'extérieur (GPS iPhone ou montre), en mètres.
    var distanceProvider: (() -> Double)?
    /// Vitesse instantanée (m/s) du GPS : sert à intégrer la distance horizontale finement pour la pente.
    var speedProvider: (() -> Double?)?
    private var lastCadenceAt: Date = .distantPast
    private var horizontal: Double = 0
    private var lastAltitudeAt: Date?

    private let motion = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()
    private var candidate: Activity = .unknown
    private var candidateSince: Date = Date()
    private var lastRawActivity: Activity = .unknown
    private var altitudeTrack: [(dist: Double, alt: Double, at: Date)] = []
    private var lastAltForCumul: Double?
    private var pendingAltDelta: Double = 0
    private var terrainCandidate: Terrain = .flat
    private var terrainCandidateSince: Date = Date()
    private var stationaryAnnounced = false
    private var timer: Timer?
    private(set) var secondsByActivity: [Activity: TimeInterval] = [:]
    private(set) var secondsClimbing: TimeInterval = 0
    private var lastTick: Date = Date()

    func start() {
        stop()
        activity = .unknown; candidate = .unknown; terrain = .flat; terrainCandidate = .flat
        activitySince = Date(); terrainSince = Date(); cadence = nil; grade = nil
        ascent = 0; descent = 0; altitudeTrack.removeAll(); lastAltForCumul = nil; pendingAltDelta = 0
        horizontal = 0; lastAltitudeAt = nil; lastCadenceAt = .distantPast
        secondsByActivity = [:]; secondsClimbing = 0; lastTick = Date(); stationaryAnnounced = false
        paused = false; runningCadences.removeAll(); typicalRunningCadence = 160

        if CMMotionActivityManager.isActivityAvailable() {
            motion.startActivityUpdates(to: .main) { [weak self] a in
                guard let self, let a else { return }
                let raw: Activity
                if a.running { raw = .running }
                else if a.walking { raw = .walking }
                else if a.cycling { raw = .cycling }
                else if a.stationary { raw = .stationary }
                else { raw = .unknown }
                // Faible confiance : on garde la valeur précédente plutôt que d'osciller.
                if a.confidence == .low, raw != .stationary { return }
                self.lastRawActivity = raw
                // Marche/course : la cadence décide (plus rapide) ; ici on ne tranche que l'arrêt et le vélo,
                // ou marche/course quand la cadence manque depuis plus de 10 s.
                if raw == .stationary || raw == .cycling || Date().timeIntervalSince(self.lastCadenceAt) > 10 {
                    self.consider(raw)
                }
            }
        }
        if CMPedometer.isCadenceAvailable() {
            pedometer.startUpdates(from: Date()) { [weak self] data, _ in
                guard let data, let c = data.currentCadence?.doubleValue else { return }
                Task { @MainActor in
                    guard let self else { return }
                    guard !self.paused else { return }
                    let spm = c * 60
                    self.cadence = spm
                    self.lastCadenceAt = Date()
                    if self.activity == .running, spm >= 130 {
                        self.runningCadences.append(spm)
                        if self.runningCadences.count > 120 { self.runningCadences.removeFirst() }
                        if self.runningCadences.count >= 20 { self.typicalRunningCadence = self.runningCadences.sorted()[self.runningCadences.count / 2] }
                    }
                    // La cadence tranche vite : ≥ 140 pas/min = course, 30-125 = marche, < 30 = arrêt.
                    if spm >= 140 { self.consider(.running) }
                    else if spm <= 125, spm >= 30 { self.consider(.walking) }
                    else if spm < 30, self.lastRawActivity != .cycling { self.consider(.stationary) }
                }
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                self.ingestAltitude(data.relativeAltitude.doubleValue)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Reprise après une mort de l'app : on repart des compteurs sauvegardés (à appeler après `start()`).
    func restore(walking: TimeInterval, running: TimeInterval, stationary: TimeInterval, climbing: TimeInterval, ascent: Double, descent: Double) {
        secondsByActivity = [.walking: walking, .running: running, .stationary: stationary].filter { $0.value > 0 }
        secondsClimbing = climbing
        self.ascent = ascent
        self.descent = descent
    }

    func stop() {
        motion.stopActivityUpdates()
        pedometer.stopUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        timer?.invalidate(); timer = nil
    }

    // MARK: Activité (hystérésis 6 s)

    private func consider(_ raw: Activity) {
        guard raw != .unknown, !paused else { return }
        if raw != candidate { candidate = raw; candidateSince = Date() }
        commitIfStable()
    }

    private func commitIfStable() {
        // 6 s de stabilité (la première détection passe immédiatement).
        let needed: TimeInterval = activity == .unknown ? 0 : 6
        guard candidate != activity, Date().timeIntervalSince(candidateSince) >= needed else { return }
        let from = activity
        activity = candidate
        // Le vrai début de l'activité, pas l'instant où l'hystérésis de 6 s la confirme.
        activitySince = candidateSince
        stationaryAnnounced = false
        onLog?("Détection : \(from.label) → \(activity.label)\(cadence.map { String(format: " (cadence %.0f)", $0) } ?? "")")
        if from != .unknown { onEvent?(.activity(from: from, to: activity)) }
    }

    // MARK: Relief

    private func ingestAltitude(_ alt: Double) {
        guard !paused else { lastAltitudeAt = nil; return }
        let now = Date()
        // Distance horizontale : vitesse GPS intégrée (fine), sinon distance externe (montre) en secours.
        if let last = lastAltitudeAt {
            let dt = now.timeIntervalSince(last)
            if let v = speedProvider?(), v >= 0 { horizontal += v * dt }
            else { horizontal = max(horizontal, distanceProvider?() ?? horizontal) }
        }
        lastAltitudeAt = now
        let dist = horizontal
        altitudeTrack.append((dist, alt, now))
        if altitudeTrack.count > 600 { altitudeTrack.removeFirst(altitudeTrack.count - 600) }
        // D+ / D- cumulés : on n'enregistre que les variations nettes d'au moins 1 m, pour ignorer le bruit.
        if let last = lastAltForCumul {
            pendingAltDelta += alt - last
            if pendingAltDelta >= 1 { ascent += pendingAltDelta; pendingAltDelta = 0 }
            else if pendingAltDelta <= -1 { descent -= pendingAltDelta; pendingAltDelta = 0 }
        }
        lastAltForCumul = alt
        // Pente sur les 15 dernières secondes (au moins 12 m parcourus pour se prononcer).
        if let ref = altitudeTrack.first(where: { now.timeIntervalSince($0.at) <= 15 }), dist - ref.dist >= 12 {
            let g = (alt - ref.alt) / (dist - ref.dist) * 100
            grade = g
            let t: Terrain = g >= 4 ? .climb : (g <= -4 ? .descent : (abs(g) < 2 ? .flat : terrainCandidate))
            if t != terrainCandidate { terrainCandidate = t; terrainCandidateSince = now }
            if terrainCandidate != terrain, now.timeIntervalSince(terrainCandidateSince) >= 6 {
                let from = terrain
                terrain = terrainCandidate
                terrainSince = now
                onLog?(String(format: "Relief : %@ → %@ (%.0f %%)", from.label, terrain.label, g))
                onEvent?(.terrain(from: from, to: terrain))
            }
        } else {
            grade = nil
        }
    }

    // MARK: Compteurs

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        guard !paused else { return }
        secondsByActivity[activity, default: 0] += dt
        if terrain == .climb { secondsClimbing += dt }
        commitIfStable()
        if activity == .stationary, !stationaryAnnounced, now.timeIntervalSince(activitySince) >= 45 {
            stationaryAnnounced = true
            onEvent?(.stationaryLong(seconds: Int(now.timeIntervalSince(activitySince))))
        }
        onTick?()
    }

    /// Résumé pour le prompt : « course depuis 3:20 · cadence 168 pas/min · montée 6 % · D+ 42 m / D- 10 m ».
    func summaryLine() -> String {
        var parts: [String] = []
        if activity != .unknown { parts.append("\(activity.label) depuis \(Formatters.elapsed(Date().timeIntervalSince(activitySince)))") }
        if let c = cadence, c > 0 { parts.append("cadence \(Int(c)) pas/min") }
        if let g = grade { parts.append("\(terrain.label)\(abs(g) >= 1.5 ? String(format: " %.0f %%", g) : "")") }
        if ascent >= 5 || descent >= 5 { parts.append("D+ \(Int(ascent)) m / D- \(Int(descent)) m") }
        return parts.joined(separator: " · ")
    }
}
