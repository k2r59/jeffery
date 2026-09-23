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
    private let deviceMotion = CMMotionManager()

    // MARK: Impact à la réception (le signal qui sépare vraiment marche et course)

    /// Pic d'accélération verticale sur la dernière seconde, en g. Marche : 1,2 à 1,6. Course : 2,5 à 4.
    /// C'est la phase aérienne de la course qui produit cette réception, quelle que soit la vitesse.
    @Published private(set) var impactG: Double?
    private var impactWindow: [Double] = []      // pics par seconde, 6 dernières secondes
    private var impactPeak: Double = 0           // pic de la seconde en cours
    private var impactSamples: [Double] = []     // |accélération verticale| brute de la seconde en cours
    /// Pics observés dans chaque état, pour se caler sur ce coureur (médiane, remplie en séance).
    private var walkImpacts: [Double] = []
    private var runImpacts: [Double] = []
    /// La montre écrit des métriques que watchOS ne calcule qu'en course : leur présence tranche.
    private var watchRunningMetricAt: Date = .distantPast
    /// Dernier verdict du classificateur d'Apple et sa confiance.
    private var appleGuess: (activity: Activity, confidence: CMMotionActivityConfidence, at: Date)?
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
        impactG = nil; impactWindow.removeAll(); impactPeak = 0; impactSamples.removeAll()
        walkImpacts.removeAll(); runImpacts.removeAll(); watchRunningMetricAt = .distantPast; appleGuess = nil

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
                if raw == .walking || raw == .running { self.appleGuess = (raw, a.confidence, Date()) }
                // Arrêt et vélo : le classificateur d'Apple tranche seul. Marche/course : voir `decide()`.
                if raw == .stationary || raw == .cycling { self.consider(raw) }
                else { self.decide() }
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
                    // Plus de verdict sur la seule cadence : elle n'est qu'un indice dans `decide()`.
                    if spm < 30, self.lastRawActivity != .cycling { self.consider(.stationary) }
                    else { self.decide() }
                }
            }
        }
        // Accéléromètre : on mesure l'impact de chaque foulée, c'est ce qui distingue la course de la marche.
        if deviceMotion.isDeviceMotionAvailable {
            deviceMotion.deviceMotionUpdateInterval = 1.0 / 50
            deviceMotion.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let self, let motion, !self.paused else { return }
                // Composante verticale de l'accélération propre (hors gravité), en g, quelle que soit l'orientation.
                let g = motion.gravity, a = motion.userAcceleration
                let vertical = abs(a.x * g.x + a.y * g.y + a.z * g.z)
                self.impactSamples.append(vertical)
                self.impactPeak = max(self.impactPeak, vertical)
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
        deviceMotion.stopDeviceMotionUpdates()
        timer?.invalidate(); timer = nil
    }

    // MARK: Impact et décision marche / course

    /// Fin de seconde : on garde le pic, on lisse sur 6 s, et on alimente la calibration de ce coureur.
    private func closeImpactSecond() {
        guard !impactSamples.isEmpty else { impactPeak = 0; return }
        impactWindow.append(impactPeak)
        if impactWindow.count > 6 { impactWindow.removeFirst() }
        impactG = impactWindow.sorted()[impactWindow.count / 2]
        impactSamples.removeAll(keepingCapacity: true)
        impactPeak = 0
        // Calibration : on n'apprend que sur les états bien établis (au moins 15 s dans l'état).
        if let g = impactG, Date().timeIntervalSince(activitySince) > 15 {
            if activity == .walking { walkImpacts.append(g); if walkImpacts.count > 240 { walkImpacts.removeFirst() } }
            if activity == .running { runImpacts.append(g); if runImpacts.count > 240 { runImpacts.removeFirst() } }
        }
    }

    private func median(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.sorted()[xs.count / 2] }

    /// Seuil d'impact séparant marche et course, en g. Par défaut 2,0 ; ajusté à mi-chemin entre les médianes
    /// observées chez ce coureur dès qu'on a assez de mesures dans les deux états.
    private var impactThreshold: Double {
        guard let w = median(walkImpacts), let r = median(runImpacts),
              walkImpacts.count >= 20, runImpacts.count >= 20, r - w > 0.5 else { return 2.0 }
        return (w + r) / 2
    }

    /// La montre vient d'écrire une métrique que watchOS ne calcule qu'en course (vitesse de course, temps de
    /// contact au sol, oscillation verticale) : preuve directe d'une foulée courue.
    func noteWatchRunningMetric() {
        watchRunningMetricAt = Date()
        decide()
    }

    /// Marche ou course, par ordre de fiabilité : métrique de course de la montre, impact à la réception,
    /// classificateur d'Apple, puis la cadence en dernier recours.
    private func decide() {
        guard !paused else { return }
        // Vélo et arrêt restent décidés par le classificateur d'Apple (voir `start()`).
        if lastRawActivity == .cycling { return }
        if Date().timeIntervalSince(watchRunningMetricAt) < 12 { consider(.running); return }
        if let g = impactG, impactWindow.count >= 3 {
            let t = impactThreshold
            // Zone franche : l'impact décide seul. Zone grise (±15 %) : on demande l'avis des autres.
            if g >= t * 1.15 { consider(.running); return }
            if g <= t * 0.85 { consider(.walking); return }
        }
        if let guess = appleGuess, guess.confidence == .high, Date().timeIntervalSince(guess.at) < 20 {
            consider(guess.activity); return
        }
        if let spm = cadence, Date().timeIntervalSince(lastCadenceAt) < 10 {
            if spm >= 150 { consider(.running) } else if spm <= 120, spm >= 30 { consider(.walking) }
        }
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
        var why = ""
        if let g = impactG { why += String(format: " impact %.1f g (seuil %.1f)", g, impactThreshold) }
        if let c = cadence { why += String(format: " · cadence %.0f", c) }
        if Date().timeIntervalSince(watchRunningMetricAt) < 12 { why += " · métrique de course de la montre" }
        onLog?("Détection : \(from.label) → \(activity.label)\(why.isEmpty ? "" : " ·" + why)")
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
        closeImpactSecond()
        decide()
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
        if let g = impactG { parts.append(String(format: "impact %.1f g", g)) }
        if let g = grade { parts.append("\(terrain.label)\(abs(g) >= 1.5 ? String(format: " %.0f %%", g) : "")") }
        if ascent >= 5 || descent >= 5 { parts.append("D+ \(Int(ascent)) m / D- \(Int(descent)) m") }
        return parts.joined(separator: " · ")
    }
}
