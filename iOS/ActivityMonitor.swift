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
    @Published private(set) var available = false

    var onEvent: ((Event) -> Void)?
    /// Distance parcourue fournie par l'extérieur (GPS iPhone ou montre), en mètres.
    var distanceProvider: (() -> Double)?

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
        secondsByActivity = [:]; secondsClimbing = 0; lastTick = Date(); stationaryAnnounced = false
        available = CMMotionActivityManager.isActivityAvailable() || CMAltimeter.isRelativeAltitudeAvailable()

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
                self.consider(raw)
            }
        }
        if CMPedometer.isCadenceAvailable() {
            pedometer.startUpdates(from: Date()) { [weak self] data, _ in
                guard let data, let c = data.currentCadence?.doubleValue else { return }
                Task { @MainActor in
                    self?.cadence = c * 60
                    // La cadence tranche quand le classificateur hésite : > 140 pas/min = course, < 125 = marche.
                    guard let self else { return }
                    if self.lastRawActivity == .unknown || self.lastRawActivity == .walking || self.lastRawActivity == .running {
                        if c * 60 >= 140 { self.consider(.running) } else if c * 60 <= 125, c * 60 > 20 { self.consider(.walking) }
                    }
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

    func stop() {
        motion.stopActivityUpdates()
        pedometer.stopUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        timer?.invalidate(); timer = nil
    }

    // MARK: Activité (hystérésis 15 s)

    private func consider(_ raw: Activity) {
        guard raw != .unknown else { return }
        if raw != candidate { candidate = raw; candidateSince = Date() }
        commitIfStable()
    }

    private func commitIfStable() {
        guard candidate != activity, Date().timeIntervalSince(candidateSince) >= 15 else { return }
        let from = activity
        activity = candidate
        activitySince = Date()
        stationaryAnnounced = false
        if from != .unknown { onEvent?(.activity(from: from, to: activity)) }
    }

    // MARK: Relief

    private func ingestAltitude(_ alt: Double) {
        let dist = distanceProvider?() ?? 0
        altitudeTrack.append((dist, alt, Date()))
        if altitudeTrack.count > 600 { altitudeTrack.removeFirst(altitudeTrack.count - 600) }
        // D+ / D- cumulés : on n'enregistre que les variations nettes d'au moins 1 m, pour ignorer le bruit.
        if let last = lastAltForCumul {
            pendingAltDelta += alt - last
            if pendingAltDelta >= 1 { ascent += pendingAltDelta; pendingAltDelta = 0 }
            else if pendingAltDelta <= -1 { descent -= pendingAltDelta; pendingAltDelta = 0 }
        }
        lastAltForCumul = alt
        // Pente sur les 100 derniers mètres parcourus (au moins 40 m pour se prononcer).
        if let ref = altitudeTrack.last(where: { dist - $0.dist >= 100 }) ?? altitudeTrack.first, dist - ref.dist >= 40 {
            let g = (alt - ref.alt) / (dist - ref.dist) * 100
            grade = g
            let t: Terrain = g >= 3 ? .climb : (g <= -3 ? .descent : (abs(g) < 1.5 ? .flat : terrainCandidate))
            if t != terrainCandidate { terrainCandidate = t; terrainCandidateSince = Date() }
            if terrainCandidate != terrain, Date().timeIntervalSince(terrainCandidateSince) >= 20 {
                let from = terrain
                terrain = terrainCandidate
                terrainSince = Date()
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
        secondsByActivity[activity, default: 0] += dt
        if terrain == .climb { secondsClimbing += dt }
        commitIfStable()
        if activity == .stationary, !stationaryAnnounced, now.timeIntervalSince(activitySince) >= 45 {
            stationaryAnnounced = true
            onEvent?(.stationaryLong(seconds: Int(now.timeIntervalSince(activitySince))))
        }
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
