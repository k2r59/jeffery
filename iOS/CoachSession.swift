import Foundation
import Combine
import UIKit
import CoreLocation
import ActivityKit
import AVFAudio

struct TranscriptLine: Identifiable, Equatable {
    enum Role: String { case user, coach, info }
    let id = UUID()
    let role: Role
    var text: String
    let at: Date

    init(role: Role, text: String, at: Date = Date()) {
        self.role = role
        self.text = text
        self.at = at
    }
}

/// Orchestre une séance : montre → métriques → contexte pour le coach vocal (OpenAI Realtime) ↔ audio.
@MainActor
final class CoachSession: ObservableObject {
    enum Phase: Equatable { case idle, connecting, live, ending }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript: [TranscriptLine] = []
    @Published private(set) var status: String = "Prêt"
    @Published private(set) var errorMessage: String?
    @Published private(set) var coachSpeaking = false {
        didSet { if coachSpeaking != oldValue { audio.setDucking(coachSpeaking); realtime.setCoachSpeaking(coachSpeaking); sendMirror(force: true) } }
    }
    @Published private(set) var userSpeaking = false
    @Published private(set) var currentZone: HeartRateZone?
    @Published private(set) var pace: String?
    @Published private(set) var reference: ReferenceStatus?
    @Published var endedSummary: SessionSummary?
    @Published private(set) var goal: SessionGoal = .free
    @Published private(set) var goalReached = false
    @Published private(set) var lastCoachLine: String?
    private var halfwayAnnounced = false
    // Accusé de réception « Je regarde. » : enregistré une fois par voix, joué localement si la réponse tarde.
    private var ackAudio: Data?
    private var capturingAck = false
    private var ackCaptureBuffer = Data()
    private var pendingGreeting = false
    private var lastAudioDeltaAt: Date = .distantPast
    private var lastAckAt: Date = .distantPast

    private var ackFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ack-\(config.voice).pcm")
    }
    private var sessionStartedAt: Date?
    private var hrSamples: [Double] = []
    /// Secondes passées dans chaque zone (Z1…Z5), pour la page stats de la montre.
    private var zoneSeconds = [Int](repeating: 0, count: 5)
    private var lastZoneSampleAt: Date?
    private var referenceTracker: ReferenceTracker?
    private var referenceName: String?
    private var lastClimbWarnAt: Date = .distantPast
    private var lastGhostWarnAt: Date = .distantPast
    private var cancellables = Set<AnyCancellable>()
    private var mirrorTimer: Timer?
    private var liveActivity: Activity<JeffreyActivityAttributes>?
    private var liveActivityStart: Date = Date()
    private var lastMirror: CoachMirror?
    /// L'iPhone a été réveillé en arrière-plan par la montre : l'audio ne peut démarrer qu'au premier plan.
    @Published private(set) var waitingForForeground = false

    let connectivity = PhoneConnectivity()
    let gps = RouteRecorder()
    let activity = ActivityMonitor()
    let appleVoice = AppleVoice()
    /// Minuteur piloté par Jeffrey (fractionné, blocs, récupération).
    @Published private(set) var timerLabel: String?
    @Published private(set) var timerEndsAt: Date?
    private var timerTask: Task<Void, Never>?
    private var timerRepeatsLeft = 0
    private var timerRestSeconds = 0
    private var timerWorkSeconds = 0
    private var timerPhaseIsWork = true
    /// Programme de séance (catalogue) déroulé bloc par bloc par le chronomètre.
    @Published private(set) var planTitle: String?
    @Published private(set) var planStep: String?
    private var planQueue: [WorkoutBlock] = []
    private(set) var planTotal = 0
    private(set) var planIndex = 0
    /// Durée du bloc de chrono en cours (travail ou récupération), pour la progression affichée.
    var currentTimerSeconds: Int { timerPhaseIsWork ? timerWorkSeconds : timerRestSeconds }

    private var useAppleVoice = false
    private var sentenceBuffer = ""
    private var textResponseBuffer = ""
    private var lastEventCueAt: Date = .distantPast
    private var hrHistory: [(Date, Double)] = []
    private var speedHistory: [(Date, Double)] = []
    private var struggleAnnouncedForClimb = false
    private var climbStartedAt: Date?
    private var lastCoachSpokeAt: Date = .distantPast
    private var fatigueAnnouncedAt: Date = .distantPast
    private var lastCueZone: HeartRateZone?
    private var lastUserSpokeAt: Date = .distantPast
    private var lastSpontaneousCueAt: Date = .distantPast
    private var lastKmAnnounced = 0
    private var lastKmAt: (km: Int, at: Date)?
    private var routineTopic = 0
    private let audio = AudioPipeline()
    /// Cerveau de Jeffrey : OpenAI Realtime (compte Jeffrey) ou Apple AI, choisi au départ de chaque séance.
    private var realtime: any CoachLink = RealtimeClient()

    private var config = CoachConfig.load()
    private var kind: WorkoutKind = .running
    private var mode: CaptureMode = .companion
    private var responseInProgress = false
    private var partialCoachLine: TranscriptLine?
    private var metricsTimer: Timer?
    private var cueTimer: Timer?
    private var goalTimer: Timer?
    private var lastInjectedSnapshot: MetricsSnapshot?
    private var lastCueAt: Date = .distantPast
    private var lastAnnouncedZone: HeartRateZone?
    private var distanceHistory: [(Date, Double)] = []
    private var reconnectAttempts = 0
    private var endTimeoutTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pendingPriorityCues: [String] = []
    /// Pause demandée localement, en attendant la confirmation de la montre.
    private var localPaused = false
    private var sessionToken = UUID()
    /// Séance reprise après une mort de l'app (point de reprise sur disque).
    private var resuming = false
    /// Un bloc du programme a sonné pendant la coupure : le suivant démarre dès que Jeffrey est de retour.
    private var pendingPlanAdvance = false
    private var timerBaseLabel = ""
    private var timerIndex = 1
    /// Référence du chien de garde montre : départ ou reprise, tant qu'aucun instantané n'est arrivé.
    private var watchdogFrom = Date()
    private var lastCheckpointAt: Date = .distantPast

    /// Rappel demandé à l'oral (outil `remind_me`) : « préviens-moi dans 5 min », « dis-moi quand ça fait 30 s que je marche ».
    private struct Reminder {
        let seconds: TimeInterval
        /// Activité à tenir sans interruption ; `nil` pour un simple délai.
        let activity: ActivityMonitor.Activity?
        let reason: String
        let createdAt: Date
    }
    private var reminders: [Reminder] = []

    /// Scène demandée par Jeffrey (zone, allure, message) : persiste jusqu'à `clear`, sauf le message (éphémère).
    @Published private(set) var requestedScene: WatchScene?
    /// Scène éphémère de fête (objectif atteint, programme fini), quelques secondes.
    private var celebrationScene: WatchScene?
    private var currentPaceSecPerKm: Double?

    var latest: MetricsSnapshot? { connectivity.latest }

    init() {
        Prefs.registerDefaults()
        connectivity.activate()
        // Les vues n'observent que la séance : tout changement d'état montre (connectée/déconnectée, signe de vie)
        // doit les redessiner, sinon le badge reste figé sur le premier rendu.
        connectivity.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        connectivity.onSnapshot = { [weak self] snap in self?.handle(snapshot: snap) }
        connectivity.onWatchRequest = { [weak self] payload in self?.handle(watchRequest: payload) }
        wireRealtime()
        audio.onCapturedPCM16 = { [weak self] data in self?.realtime.appendAudio(data) }
        audio.onRouteChanged = { [weak self] name in
            Task { @MainActor in self?.status = "Audio : \(name)" }
        }
        gps.$lastLocation
            .compactMap { $0 }
            .sink { [weak self] location in self?.handle(location: location) }
            .store(in: &cancellables)
        appleVoice.onIdle = { [weak self] in
            Task { @MainActor in
                guard let self, self.useAppleVoice else { return }
                self.coachSpeaking = false
                if self.phase == .ending, !self.responseInProgress { self.finishTeardown() }
            }
        }
        activity.distanceProvider = { [weak self] in self?.displayDistance ?? 0 }
        activity.speedProvider = { [weak self] in self?.gps.speed }
        activity.onLog = { [weak self] text in self?.log(.info, text) }
        activity.onEvent = { [weak self] event in self?.handle(activityEvent: event) }
        activity.onTick = { [weak self] in self?.checkReminders() }
        // Fermeture de l'app par l'utilisateur (balayage dans le sélecteur) : c'est une fin de séance, pas une panne.
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleAppTermination() }
        }
    }

    /// iOS laisse quelques secondes avant de tuer le processus : montre arrêtée, Live Activity fermée, séance gardée
    /// dans l'historique (sans bilan), point de reprise effacé pour ne pas reprendre au prochain lancement.
    private func handleAppTermination() {
        guard phase == .connecting || phase == .live else { return }
        log(.info, "Application fermée par l'utilisateur : séance terminée.")
        connectivity.send(command: .end, kind: kind, mode: mode)
        if let start = sessionStartedAt, hrSamples.count + transcript.count > 2, !goal.isTrial {
            let elapsed = latest.map { $0.state == .running ? $0.elapsed + Date().timeIntervalSince($0.timestamp) : $0.elapsed } ?? Date().timeIntervalSince(start)
            SessionSummary.upsert(makeSummary(start: start, elapsed: elapsed))
        }
        writeSessionJournal()
        SessionCheckpoint.clear()
        endLiveActivity()
        realtime.disconnect()
        phase = .idle
    }

    /// Marche, course, arrêt, montée, descente : Jeffrey réagit, avec au plus une réaction toutes les 30 s.
    private func handle(activityEvent event: ActivityMonitor.Event) {
        guard phase == .live, config.autoCues, !isPaused else { return }
        let now = Date()
        guard now.timeIntervalSince(lastEventCueAt) >= 30 else { return }
        let reason: String
        switch event {
        case .activity(let from, let to):
            switch (from, to) {
            case (.running, .walking):
                if activity.terrain == .climb {
                    struggleAnnouncedForClimb = true
                    reason = "il passe à la marche dans la montée : c'est dur, soutiens-le, marcher est un bon choix, propose de repartir en haut"
                } else {
                    reason = "il vient de passer de la course à la marche (pause marchée ou fatigue ?) : accompagne sans juger, propose de repartir quand il veut"
                }
            case (.walking, .running):
                // Pas de « c'est bien, garde ça » quatre secondes après le départ : on attend que les données bougent.
                let token = sessionToken
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    guard let self, self.sessionToken == token, self.phase == .live, self.activity.activity == .running else { return }
                    self.cue(reason: "il court depuis 25 s après une reprise : un mot sur ce que disent les données maintenant (FC, allure), pas de bravo réflexe")
                }
                return
            case (_, .stationary): return // annoncé seulement si l'arrêt dure
            case (.stationary, .running), (.stationary, .walking): reason = "il repart après un arrêt"
            default: reason = "activité détectée : \(to.label) (avant : \(from.label))"
            }
        case .terrain(let from, let to):
            let g = activity.grade ?? 0
            switch to {
            case .climb:
                climbStartedAt = now
                struggleAnnouncedForClimb = false
                guard g >= 5 else { return } // une côte douce ne mérite pas de commentaire
                reason = String(format: "début d'une vraie montée (%.0f %%) : un mot pour le préparer, la FC va monter, c'est normal", g)
            case .descent:
                guard g <= -5 else { return }
                reason = "début d'une descente raide : relâcher les épaules, foulée courte, pas de freinage"
            case .flat:
                let climbDuration = climbStartedAt.map { now.timeIntervalSince($0) } ?? 0
                climbStartedAt = nil
                guard from == .climb, climbDuration >= 45 else { return }
                reason = "sommet atteint après \(Int(climbDuration)) s de montée : félicite, invite à reprendre l'allure progressivement"
            }
        case .stationaryLong(let seconds):
            reason = "à l'arrêt depuis \(seconds) s (feu, pause ?) : demande si tout va bien, propose la pause si besoin"
        }
        lastEventCueAt = now
        cue(reason: reason)
    }

    // MARK: - Démarrage / arrêt

    /// La montre est le capteur : sans elle, pas de séance. Même vérité que le badge « Montre connectée » de l'iPhone,
    /// et même règle pour un départ demandé depuis la montre.
    var watchReady: Bool { connectivity.isPaired && connectivity.isWatchAppInstalled && connectivity.watchConnected }

    func start(kind: WorkoutKind, mode: CaptureMode, goal: SessionGoal = .free) {
        guard phase == .idle else { return }
        if AVAudioApplication.shared.recordPermission != .granted {
            Task { [weak self] in
                let ok = await AudioPipeline.requestMicrophonePermission()
                guard let self else { return }
                if ok { self.start(kind: kind, mode: mode, goal: goal) } else { self.errorMessage = "Micro refusé : Jeffrey ne peut pas t'entendre (Réglages › Jeffrey › Micro)." }
            }
            return
        }
        config = CoachConfig.load()
        #if DEBUG
        if FakeRealtimeBackend.enabled, config.apiKey.isEmpty { config.apiKey = "fake" }
        #endif
        guard watchReady else {
            errorMessage = "Montre déconnectée : " + connectivity.disconnectedHint.prefix(1).lowercased() + connectivity.disconnectedHint.dropFirst()
            return
        }
        self.goal = goal
        goalReached = false
        halfwayAnnounced = false
        lastCoachLine = nil
        guard config.usesAppleAI || OpenAIAccess.isConfigured || !config.apiKey.isEmpty else {
            errorMessage = "Connecte-toi avec Apple (onglet Jeffrey) pour lancer une séance."
            return
        }
        selectLink()
        self.kind = kind
        self.mode = mode
        errorMessage = nil
        transcript.removeAll()
        distanceHistory.removeAll()
        lastInjectedSnapshot = nil
        reminders.removeAll()
        requestedScene = nil
        celebrationScene = nil
        currentPaceSecPerKm = nil
        lastAnnouncedZone = nil
        currentZone = nil
        pace = nil
        reconnectAttempts = 0
        resuming = false
        pendingPlanAdvance = false
        phase = .connecting
        status = "Connexion au coach…"
        sessionStartedAt = Date()
        watchdogFrom = Date()
        lastMirror = nil
        hrSamples.removeAll()
        zoneSeconds = [Int](repeating: 0, count: 5)
        lastZoneSampleAt = nil
        hrHistory.removeAll(); speedHistory.removeAll()
        lastUserSpokeAt = .distantPast; lastSpontaneousCueAt = .distantPast
        struggleAnnouncedForClimb = false; climbStartedAt = nil; lastCoachSpokeAt = .distantPast; fatigueAnnouncedAt = .distantPast; lastCueZone = nil
        lastKmAnnounced = 0; lastKmAt = nil; routineTopic = 0
        // Repart propre : l'instantané de la séance précédente ne doit pas nourrir celle-ci.
        connectivity.reset()
        connectivity.acceptSnapshotsSince = Date().addingTimeInterval(-3)
        connectivity.requestHealthAuthorization()
        UIApplication.shared.isIdleTimerDisabled = true
        audio.duckOthersWhileSpeaking = UserDefaults.standard.object(forKey: Prefs.duckMusic) as? Bool ?? true
        audio.noiseGate = config.micSensitivity.noiseGate
        audio.voiceGain = (UserDefaults.standard.object(forKey: Prefs.voiceBoost) as? Bool ?? true) ? 1.8 : 1.0
        useAppleVoice = config.voiceEngine == "apple" || config.usesAppleAI
        audio.useHeadsetMic = (UserDefaults.standard.string(forKey: Prefs.micSource) ?? "headset") == "headset"
        appleVoice.refresh()
        sentenceBuffer = ""; textResponseBuffer = ""
        gps.start(kind: kind)
        activity.start()
        lastEventCueAt = .distantPast
        if let ref = ReferenceRoute.load() {
            referenceTracker = ReferenceTracker(route: ref)
            referenceName = ref.name
            reference = nil
        } else {
            referenceTracker = nil
            referenceName = nil
            reference = nil
        }

        sessionToken = UUID()
        localPaused = false
        pendingPriorityCues.removeAll()
        partialCoachLine = nil
        // Micro et session audio ouverts tout de suite, tant que l'app est visible : ils continuent ensuite en arrière-plan.
        if UIApplication.shared.applicationState == .active {
            do { try audio.start() } catch {
                var tolerate = false
                #if DEBUG
                tolerate = FakeRealtimeBackend.enabled
                #endif
                if !tolerate {
                    errorMessage = "Audio : \(error.localizedDescription)"
                    phase = .idle
                    return
                }
            }
        }
        connectRealtime()
        endOrphanLiveActivities()
        startLiveActivity()
        saveCheckpoint()
        let token = sessionToken
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.sessionToken == token, self.phase == .connecting, !self.waitingForForeground else { return }
            self.errorMessage = self.errorMessage ?? "Connexion au coach impossible (délai dépassé)."
            self.stop(reason: "coach injoignable après 25 s (\(self.errorMessage ?? ""))")
        }

        // Côté montre : lancement de la séance pilotée, ou demande de suivi de l'app Exercice.
        switch mode {
        case .owned:
            // App montre éveillée : on lui envoie la commande directement (startWatchApp échoue quand l'iPhone est en
            // arrière-plan, cas d'un départ demandé depuis la montre). Sinon on réveille l'app montre.
            if connectivity.isReachable {
                connectivity.send(command: .start, kind: kind, mode: .owned) { [weak self] error in
                    guard let self else { return }
                    if error == nil { self.log(.info, "Séance lancée sur la montre (commande directe)."); return }
                    self.launchWatchWorkoutLogged(kind: kind)
                }
            } else {
                launchWatchWorkoutLogged(kind: kind)
            }
        case .companion:
            connectivity.send(command: .start, kind: kind, mode: .companion) { [weak self] error in
                guard let self else { return }
                if error == nil {
                    self.log(.info, "La montre suit l'app Exercice. Lance ta séance dans l'app Exercice si ce n'est pas fait.")
                    return
                }
                // Montre non joignable : on réveille l'app montre, qui lit la commande déposée et passe en mode compagnon.
                self.connectivity.launchWatchWorkout(kind: kind) { error in
                    if let error {
                        self.log(.info, "Montre : \(error.localizedDescription). Ouvre Jeffrey sur la montre et touche « Suivre l'app Exercice ».")
                    } else {
                        self.log(.info, "Jeffrey réveillé sur la montre, il suit l'app Exercice.")
                    }
                }
            }
        }
    }

    private func launchWatchWorkoutLogged(kind: WorkoutKind) {
        connectivity.launchWatchWorkout(kind: kind) { [weak self] error in
            guard let self else { return }
            if let error {
                self.log(.info, "Lancement montre : \(error.localizedDescription). Démarre la séance depuis la montre.")
            } else {
                self.log(.info, "Séance lancée sur la montre.")
            }
        }
    }

    /// Télécommande montre : la montre ne décide de rien, elle demande à l'iPhone. Retourne la raison d'un refus.
    @discardableResult
    private func handle(watchRequest payload: WatchCommandPayload) -> String? {
        var refusal: String?
        switch payload.command {
        case .requestStart:
            guard phase == .idle else { break }
            // Même porte que le bouton de l'iPhone : pas de « Montre connectée » à l'écran, pas de départ.
            guard watchReady else {
                refusal = "L'iPhone ne voit pas la montre connectée. Rapproche-le, garde Jeffrey ouvert sur la montre et réessaie."
                errorMessage = "Départ refusé depuis la montre : " + connectivity.linkLabel.lowercased() + "."
                log(.info, "Départ montre refusé : montre déconnectée côté iPhone")
                break
            }
            let mode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: Prefs.mode) ?? "") ?? .companion
            UserDefaults.standard.set(payload.kind.rawValue, forKey: Prefs.kind)
            start(kind: payload.kind, mode: mode, goal: .free)
            // Toujours à l'arrêt avec un message : start() a refusé (micro, compte…) ; la montre doit le savoir.
            if phase == .idle, let message = errorMessage { refusal = message }
        case .requestPause, .requestResume:
            togglePause()
        case .ask:
            // Bouton de la page Jeffrey sur la montre : la question passe comme s'il l'avait dite.
            guard phase == .live, let text = payload.text, !text.isEmpty else { refusal = "Jeffrey n'est pas en ligne"; break }
            log(.user, text + " (montre)")
            lastUserSpokeAt = Date()
            realtime.injectText(text, role: "user", itemId: nil)
            if !(realtime is AppleCoachLink) { realtime.requestResponse() }
        case .requestEnd:
            if phase == .idle {
                // Rien en cours côté iPhone : la montre doit quand même arrêter sa capture.
                connectivity.send(command: .end, kind: payload.kind, mode: .companion)
            } else {
                stop(reason: "Terminer touché sur la montre")
            }
        default:
            break
        }
        sendMirror(force: true)
        return refusal
    }

    /// Reprise quand l'app revient au premier plan (audio impossible à démarrer en arrière-plan).
    func resumeIfWaitingForForeground() {
        guard waitingForForeground, phase == .connecting else { return }
        waitingForForeground = false
        onRealtimeReady()
    }

    private func mirrorSnapshot() -> CoachMirror {
        let elapsed = liveElapsed()
        let p = goal.kind == .free ? (fraction: 0.0, remaining: nil as String?) : goal.progress(elapsed: elapsed, distance: displayDistance)
        let phaseName: String
        switch phase { case .idle: phaseName = "idle"; case .connecting: phaseName = waitingForForeground ? "foreground" : "connecting"; case .live: phaseName = "live"; case .ending: phaseName = "ending" }
        return CoachMirror(phase: phaseName, elapsed: elapsed, timestamp: Date(), kind: kind,
                           goalLabel: goal.kind == .free ? nil : goal.label, remaining: p.remaining, progress: p.fraction,
                           goalReached: goalReached, coachSpeaking: coachSpeaking, userSpeaking: userSpeaking,
                           lastLine: lastCoachLine.map { String($0.prefix(140)) }, heartRate: latest?.heartRate,
                           distance: displayDistance, paused: isPaused, timerLabel: mirrorTimerLabel, timerEndsAt: timerEndsAt,
                           scene: currentScene(), paceSecPerKm: currentPaceSecPerKm,
                           zoneSeconds: zoneSeconds.reduce(0, +) > 0 ? zoneSeconds : nil,
                           averageHeartRate: hrSamples.isEmpty ? nil : hrSamples.reduce(0, +) / Double(hrSamples.count),
                           energy: latest?.activeEnergy,
                           averageSpeed: (displayDistance ?? 0) > 20 && elapsed > 30 ? displayDistance! / elapsed : nil,
                           zone: currentZone?.rawValue,
                           planStep: planTotal > 0 ? "Bloc \(planIndex) / \(planTotal)" : (timerRepeatsLeft > 1 ? "Répétition · reste \(timerRepeatsLeft)" : nil),
                           planNext: mirrorPlanNext)
    }

    /// Ce qui suit le bloc en cours, pour la page Intervalles de la montre.
    private var mirrorPlanNext: String? {
        guard timerLabel != nil else { return nil }
        if timerPhaseIsWork, timerRepeatsLeft > 1 {
            return timerRestSeconds > 0 ? "récup · \(Formatters.humanDuration(TimeInterval(timerRestSeconds)))" : "répétition suivante"
        }
        if !timerPhaseIsWork { return "effort · \(Formatters.humanDuration(TimeInterval(timerWorkSeconds)))" }
        if let n = planQueue.first { return "\(n.label) · \(Formatters.humanDuration(TimeInterval(n.seconds)))" }
        return nil
    }

    // MARK: - Scènes de la montre

    /// La scène à afficher maintenant, par priorité : message de Jeffrey, fête, chrono, cible (zone/allure), montée, fantôme.
    private func currentScene() -> WatchScene? {
        let now = Date()
        if let r = requestedScene, r.kind == .message {
            if let until = r.until, until > now { return r }
        }
        if let c = celebrationScene {
            if let until = c.until, until > now { return c }
            celebrationScene = nil
        }
        if let label = timerLabel, let end = timerEndsAt {
            let isPlanOrRepeat = planTitle != nil || timerRepeatsLeft > 1 || !timerPhaseIsWork
            let start = end.addingTimeInterval(-TimeInterval(timerPhaseIsWork ? timerWorkSeconds : timerRestSeconds))
            var next: String?
            if timerPhaseIsWork, timerRepeatsLeft > 1 {
                next = timerRestSeconds > 0 ? "récup \(Formatters.humanDuration(TimeInterval(timerRestSeconds))) ensuite" : "puis répétition suivante"
            } else if !timerPhaseIsWork {
                next = "puis effort \(Formatters.humanDuration(TimeInterval(timerWorkSeconds)))"
            } else if let n = planQueue.first {
                next = "puis \(n.label) · \(Formatters.humanDuration(TimeInterval(n.seconds)))"
            }
            return WatchScene(kind: isPlanOrRepeat ? .interval : .countdown, id: "timer-\(label)-\(Int(end.timeIntervalSince1970))",
                              title: label.capitalized, subtitle: next, caption: planTitle.map { "\($0) · \(planStep ?? "")" },
                              startsAt: start, endsAt: end, phase: timerPhaseIsWork ? "work" : "rest")
        }
        if let r = requestedScene, r.kind != .message {
            var scene = r
            if r.kind == .pace { scene.value = currentPaceSecPerKm }
            return scene
        }
        if activity.terrain == .climb, let g = activity.grade, g >= 3 {
            var sub = String(format: "D+ %.0f m depuis le départ", activity.ascent)
            if let ref = reference, ref.gainNext >= 8 { sub = String(format: "encore +%.0f m sur 500 m", ref.gainNext) }
            return WatchScene(kind: .climb, id: "climb-\(Int(activity.terrainSince.timeIntervalSince1970))",
                              title: String(format: "Montée · %.0f %%", g), subtitle: sub,
                              caption: lastCoachLine.map { String($0.prefix(60)) }, value: g, progress: activity.ascent)
        }
        if let ref = reference, !ref.offRoute, let ghost = ref.ghostDelta, let name = referenceName {
            return WatchScene(kind: .ghost, id: "ghost-\(name)", title: "Fantôme · \(name)",
                              subtitle: "\(Formatters.distance(ref.covered)) · reste \(Formatters.distance(max(0, ref.total - ref.covered)))",
                              value: ghost, progress: ref.total > 0 ? min(1, ref.covered / ref.total) : 0)
        }
        return nil
    }

    private func celebrate(_ title: String, subtitle: String?, seconds: TimeInterval = 8) {
        celebrationScene = WatchScene(kind: .celebration, id: "fete-\(Int(Date().timeIntervalSince1970))", title: title, subtitle: subtitle,
                                      until: Date().addingTimeInterval(seconds))
        sendMirror(force: true)
    }

    /// Outil show_on_watch : Jeffrey choisit ce que la montre affiche.
    private func handleShowOnWatch(callId: String, json: [String: Any]) {
        let what = (json["what"] as? String ?? "").lowercased()
        switch what {
        case "zone":
            let z = HeartRateZone(rawValue: max(1, min(5, (json["zone"] as? Int) ?? 2))) ?? .z2
            let b = z.bounds(maxHR: config.maxHR)
            requestedScene = WatchScene(kind: .zone, id: "zone-\(z.rawValue)-\(Int(Date().timeIntervalSince1970))",
                                        title: "Reste en \(z.label)", subtitle: "cible \(Int(b.low)) – \(Int(b.high))", low: b.low, high: b.high, zone: z.rawValue)
            log(.info, "Montre : cible \(z.label) (\(Int(b.low))–\(Int(b.high)) bpm)")
        case "pace":
            let text = (json["pace"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let parts = text.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { realtime.sendFunctionOutput(callId: callId, output: ["error": "allure attendue au format m:ss"]); return }
            let target = parts[0] * 60 + parts[1]
            let tol = max(5, (json["tolerance_seconds"] as? Double) ?? 10)
            requestedScene = WatchScene(kind: .pace, id: "pace-\(Int(target))-\(Int(Date().timeIntervalSince1970))",
                                        title: "Allure cible \(text)", subtitle: "min/km", low: target - tol, high: target + tol, value: currentPaceSecPerKm)
            log(.info, "Montre : allure cible \(text) ±\(Int(tol)) s")
        case "message":
            let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { realtime.sendFunctionOutput(callId: callId, output: ["error": "texte vide"]); return }
            let seconds = min(30, max(3, (json["seconds"] as? Double) ?? 8))
            requestedScene = WatchScene(kind: .message, id: "msg-\(Int(Date().timeIntervalSince1970))", title: "Jeffrey", subtitle: String(text.prefix(90)),
                                        until: Date().addingTimeInterval(seconds))
            log(.info, "Montre : « \(text) »")
        case "clear":
            requestedScene = nil
            log(.info, "Montre : retour à l'écran normal")
        default:
            realtime.sendFunctionOutput(callId: callId, output: ["error": "what doit valoir zone, pace, message ou clear"])
            return
        }
        sendMirror(force: true)
        realtime.sendFunctionOutput(callId: callId, output: ["shown": what], thenRespond: false)
    }

    private var mirrorTimerLabel: String? {
        guard let timerLabel else { return nil }
        return planStep.map { "\(timerLabel) · \($0)" } ?? timerLabel
    }

    // MARK: - Live Activity (écran verrouillé, Dynamic Island, Smart Stack de la montre)

    private func activityState() -> JeffreyActivityAttributes.ContentState {
        let elapsed = liveElapsed()
        let p = goal.kind == .free ? (fraction: 0.0, remaining: nil as String?) : goal.progress(elapsed: elapsed, distance: displayDistance)
        return JeffreyActivityAttributes.ContentState(
            startedAt: Date().addingTimeInterval(-elapsed), paused: isPaused, elapsedFrozen: elapsed,
            heartRate: latest?.heartRate.map { Int($0) }, distanceMeters: displayDistance,
            goalLabel: goal.kind == .free ? nil : goal.label, remaining: p.remaining, progress: p.fraction,
            coachState: phase == .connecting ? "arrive" : (coachSpeaking ? "parle" : "ecoute"),
            lastLine: lastCoachLine.map { String($0.prefix(120)) }, timerLabel: mirrorTimerLabel, timerEndsAt: timerEndsAt)
    }

    /// Sans nouvelle de l'app passé ce délai, l'écran verrouillé dit que Jeffrey ne répond plus.
    private var liveActivityStaleDate: Date { Date().addingTimeInterval(120) }

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = JeffreyActivityAttributes(kindLabel: kind.label)
        liveActivity = try? Activity.request(attributes: attributes, content: .init(state: activityState(), staleDate: liveActivityStaleDate))
    }

    /// Reprise : on récupère la Live Activity laissée par l'app morte plutôt que d'en empiler une deuxième.
    private func adoptOrStartLiveActivity() {
        if let existing = Activity<JeffreyActivityAttributes>.activities.first {
            liveActivity = existing
            for extra in Activity<JeffreyActivityAttributes>.activities.dropFirst() {
                Task { await extra.end(nil, dismissalPolicy: .immediate) }
            }
            updateLiveActivity()
        } else {
            startLiveActivity()
        }
    }

    /// Live Activity d'une séance dont on n'a plus trace (app morte, pas de reprise) : on la ferme.
    private func endOrphanLiveActivities() {
        for activity in Activity<JeffreyActivityAttributes>.activities where activity.id != liveActivity?.id {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func updateLiveActivity() {
        guard let activity = liveActivity else { return }
        let state = activityState()
        let stale = liveActivityStaleDate
        Task { await activity.update(.init(state: state, staleDate: stale)) }
    }

    private func endLiveActivity() {
        guard let activity = liveActivity else { return }
        liveActivity = nil
        let state = activityState()
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(300))) }
    }

    private func sendMirror(force: Bool = false) {
        let m = mirrorSnapshot()
        if !force, let last = lastMirror, last.phase == m.phase, last.coachSpeaking == m.coachSpeaking, last.userSpeaking == m.userSpeaking,
           last.lastLine == m.lastLine, last.paused == m.paused, abs(last.elapsed - m.elapsed) < 4, last.goalReached == m.goalReached,
           last.timerLabel == m.timerLabel, last.scene?.id == m.scene?.id, last.scene?.value == m.scene?.value { return }
        lastMirror = m
        updateLiveActivity()
        connectivity.sendCoachState(m)
        if force || Date().timeIntervalSince(lastCheckpointAt) > 15 { saveCheckpoint() }
    }

    /// Arrête la séance. `reason` est journalisé : chaque chemin d'arrêt doit dire pourquoi (séance du 20/09 arrêtée
    /// 15 s après le départ sans aucune trace de la cause).
    func stop(reason: String? = nil) {
        guard phase == .connecting || phase == .live else { return }
        log(.info, "Arrêt de la séance : \(reason ?? "demandé par l'utilisateur (Terminer)")")
        let wasLive = phase == .live
        connectTimeoutTask?.cancel(); connectTimeoutTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        realtime.cancelPendingResponses()
        pendingPriorityCues.removeAll()
        phase = .ending
        if !wasLive { finishTeardown(); return }
        status = "Fin de séance…"
        stopTimers()
        cancelTimer()
        gps.stop()
        activity.stop()
        if !gps.status.isEmpty { log(.info, gps.status) }
        if mode == .owned {
            connectivity.send(command: .end, kind: kind, mode: mode)
        } else {
            connectivity.send(command: .end, kind: kind, mode: mode)
        }
        if realtime.isConnected {
            audio.onCapturedPCM16 = nil
            realtime.injectText(metricsLine(prefix: "[MÉTRIQUES FINALES]") + "\nLa séance est terminée.")
            realtime.requestResponse(instructions: "La séance est terminée : fais un débrief en 2 phrases max, chaleureux et concret, puis dis au revoir.")
            endTimeoutTask?.cancel()
            endTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self?.finishTeardown()
            }
        } else {
            finishTeardown()
        }
    }

    var isPaused: Bool { localPaused || latest?.state == .paused }

    /// Temps écoulé « vrai » : dernier instantané de la montre + temps passé depuis, ou horloge locale sans montre.
    func liveElapsed(at now: Date = Date()) -> TimeInterval {
        if let s = latest, s.state != .idle {
            if s.state == .running, phase != .idle { return s.elapsed + max(0, now.timeIntervalSince(s.timestamp)) }
            return s.elapsed
        }
        if let start = sessionStartedAt, phase != .idle { return now.timeIntervalSince(start) }
        return 0
    }

    func togglePause() {
        guard phase == .live else { return }
        let command: WatchCommand = isPaused ? .resume : .pause
        localPaused = command == .pause
        gps.paused = localPaused
        activity.paused = localPaused
        connectivity.send(command: command, kind: kind, mode: mode) { [weak self] error in
            if let error { self?.log(.info, "Montre : \(error.localizedDescription)") }
        }
        realtime.injectText(command == .pause ? "L'utilisateur met la séance en pause : plus de coaching jusqu'à la reprise." : "L'utilisateur reprend la séance.")
        sendMirror(force: true)
    }

    private func finishTeardown() {
        guard phase == .ending else { return }
        endTimeoutTask?.cancel()
        endTimeoutTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        reminders.removeAll()
        realtime.disconnect()
        appleVoice.stop()
        audio.stop()
        endLiveActivity()
        audio.onCapturedPCM16 = { [weak self] data in self?.realtime.appendAudio(data) }
        UIApplication.shared.isIdleTimerDisabled = false
        responseInProgress = false
        coachSpeaking = false
        userSpeaking = false
        partialCoachLine = nil
        localPaused = false
        phase = .idle
        status = "Séance terminée"
        waitingForForeground = false
        sendMirror(force: true)
        // Journal écrit tant que le départ de séance est connu : les horodatages s'y réfèrent.
        writeSessionJournal()
        // Le tour d'essai de l'onboarding ne laisse pas de séance dans l'historique.
        if let start = sessionStartedAt, hrSamples.count + transcript.count > 2, !goal.isTrial {
            let elapsed = latest.map { $0.state == .running ? $0.elapsed + Date().timeIntervalSince($0.timestamp) : $0.elapsed } ?? Date().timeIntervalSince(start)
            endedSummary = makeSummary(start: start, elapsed: elapsed)
        }
        sessionStartedAt = nil
        resuming = false
        pendingPlanAdvance = false
        SessionCheckpoint.clear()
    }

    private func makeSummary(start: Date, elapsed: TimeInterval) -> SessionSummary {
        SessionSummary(
            id: ISO8601DateFormatter().string(from: start), date: latest?.sessionStart ?? start, kind: kind,
            elapsed: elapsed,
            distance: displayDistance,
            averageHeartRate: hrSamples.isEmpty ? nil : hrSamples.reduce(0, +) / Double(hrSamples.count),
            maxHeartRate: hrSamples.max(), feeling: nil,
            goalLabel: goal.kind == .free ? nil : goal.label, goalReached: goal.kind == .free ? nil : goalReached,
            lastCoachLine: transcript.last(where: { $0.role == .coach })?.text,
            zoneCounts: HeartRateZone.allCases.map { z in hrSamples.filter { HeartRateZone.zone(for: $0, maxHR: config.maxHR) == z }.count },
            transcriptExcerpt: transcript.filter { $0.role != .info }.suffix(80).map { ($0.role == .user ? "Lui : " : "Jeffrey : ") + $0.text },
            walkingSeconds: activity.secondsByActivity[.walking], runningSeconds: activity.secondsByActivity[.running],
            stationarySeconds: activity.secondsByActivity[.stationary], ascent: activity.ascent, descent: activity.descent,
            climbingSeconds: activity.secondsClimbing)
    }

    // MARK: - Point de reprise (l'app meurt, la séance survit)

    /// État de la séance sur disque, réécrit à chaque événement et au moins toutes les 15 s ; le journal suit,
    /// pour qu'une séance interrompue laisse quand même sa trace.
    private func saveCheckpoint() {
        guard phase == .connecting || phase == .live, let start = sessionStartedAt else { return }
        lastCheckpointAt = Date()
        var timer: SessionCheckpoint.TimerState?
        if let label = timerLabel, let end = timerEndsAt {
            timer = .init(label: label, baseLabel: timerBaseLabel, index: timerIndex, endsAt: end, workSeconds: timerWorkSeconds,
                          restSeconds: timerRestSeconds, repeatsLeft: timerRepeatsLeft, phaseIsWork: timerPhaseIsWork)
        }
        let plan = planTitle.map { SessionCheckpoint.PlanState(title: $0, queue: planQueue, total: planTotal, index: planIndex) }
        SessionCheckpoint(
            kind: kind, mode: mode, goal: goal, goalReached: goalReached, halfwayAnnounced: halfwayAnnounced,
            startedAt: start, savedAt: Date(),
            transcript: transcript.map { .init(role: $0.role.rawValue, text: $0.text, at: $0.at) },
            hrSamples: hrSamples, zoneSeconds: zoneSeconds, lastKmAnnounced: lastKmAnnounced,
            timer: timer, plan: plan, routeID: gps.routeID,
            walkingSeconds: activity.secondsByActivity[.walking] ?? 0, runningSeconds: activity.secondsByActivity[.running] ?? 0,
            stationarySeconds: activity.secondsByActivity[.stationary] ?? 0, climbingSeconds: activity.secondsClimbing,
            ascent: activity.ascent, descent: activity.descent
        ).save()
        writeSessionJournal()
    }

    /// Au lancement : une séance était en cours quand l'app s'est arrêtée. Récente, on la reprend là où elle en
    /// était ; trop vieille, on la clôt proprement avec ce qu'on a (bilan, journal, montre prévenue).
    func recoverIfNeeded() {
        guard phase == .idle else { return }
        guard let checkpoint = SessionCheckpoint.load() else { endOrphanLiveActivities(); return }
        restore(checkpoint)
        guard checkpoint.isResumable else {
            log(.info, "Séance interrompue il y a \(Int(checkpoint.age / 60)) min : close sans reprise.")
            endOrphanLiveActivities()
            connectivity.send(command: .end, kind: kind, mode: mode)
            if hrSamples.count + transcript.count > 2 {
                endedSummary = makeSummary(start: checkpoint.startedAt, elapsed: checkpoint.savedAt.timeIntervalSince(checkpoint.startedAt))
            }
            writeSessionJournal()
            SessionCheckpoint.clear()
            sessionStartedAt = nil
            return
        }
        resumeSession(interruptedFor: checkpoint.age, checkpoint: checkpoint)
    }

    private func restore(_ c: SessionCheckpoint) {
        kind = c.kind
        mode = c.mode
        goal = c.goal
        goalReached = c.goalReached
        halfwayAnnounced = c.halfwayAnnounced
        sessionStartedAt = c.startedAt
        transcript = c.transcript.map { TranscriptLine(role: TranscriptLine.Role(rawValue: $0.role) ?? .info, text: $0.text, at: $0.at) }
        lastCoachLine = transcript.last(where: { $0.role == .coach })?.text
        hrSamples = c.hrSamples
        zoneSeconds = c.zoneSeconds.count == 5 ? c.zoneSeconds : [Int](repeating: 0, count: 5)
        lastKmAnnounced = c.lastKmAnnounced
        if let p = c.plan {
            planTitle = p.title; planQueue = p.queue; planTotal = p.total; planIndex = p.index; planStep = "bloc \(p.index)/\(p.total)"
        }
    }

    private func resumeSession(interruptedFor gap: TimeInterval, checkpoint c: SessionCheckpoint) {
        config = CoachConfig.load()
        #if DEBUG
        if FakeRealtimeBackend.enabled, config.apiKey.isEmpty { config.apiKey = "fake" }
        #endif
        guard config.usesAppleAI || OpenAIAccess.isConfigured || !config.apiKey.isEmpty else {
            errorMessage = "Connecte-toi avec Apple (onglet Jeffrey) pour reprendre la séance."
            SessionCheckpoint.clear()
            sessionStartedAt = nil
            return
        }
        selectLink()
        resuming = true
        pendingPlanAdvance = false
        errorMessage = nil
        reconnectAttempts = 0
        phase = .connecting
        status = "Jeffrey revient…"
        watchdogFrom = Date()
        lastMirror = nil
        lastZoneSampleAt = nil
        distanceHistory.removeAll(); lastInjectedSnapshot = nil; reminders.removeAll()
        requestedScene = nil; celebrationScene = nil; currentPaceSecPerKm = nil; lastAnnouncedZone = nil; currentZone = nil; pace = nil
        hrHistory.removeAll(); speedHistory.removeAll()
        lastUserSpokeAt = .distantPast; lastSpontaneousCueAt = .distantPast; lastEventCueAt = .distantPast
        struggleAnnouncedForClimb = false; climbStartedAt = nil; lastCoachSpokeAt = .distantPast; fatigueAnnouncedAt = .distantPast; lastCueZone = nil
        lastKmAt = nil; routineTopic = 0
        connectivity.reset()
        connectivity.acceptSnapshotsSince = Date().addingTimeInterval(-3)
        connectivity.requestHealthAuthorization()
        UIApplication.shared.isIdleTimerDisabled = true
        audio.duckOthersWhileSpeaking = UserDefaults.standard.object(forKey: Prefs.duckMusic) as? Bool ?? true
        audio.noiseGate = config.micSensitivity.noiseGate
        audio.voiceGain = (UserDefaults.standard.object(forKey: Prefs.voiceBoost) as? Bool ?? true) ? 1.8 : 1.0
        useAppleVoice = config.voiceEngine == "apple" || config.usesAppleAI
        audio.useHeadsetMic = (UserDefaults.standard.string(forKey: Prefs.micSource) ?? "headset") == "headset"
        appleVoice.refresh()
        sentenceBuffer = ""; textResponseBuffer = ""
        gps.start(kind: kind, resuming: c.routeID)
        activity.start()
        activity.restore(walking: c.walkingSeconds, running: c.runningSeconds, stationary: c.stationarySeconds,
                         climbing: c.climbingSeconds, ascent: c.ascent, descent: c.descent)
        if let ref = ReferenceRoute.load() {
            referenceTracker = ReferenceTracker(route: ref)
            referenceName = ref.name
        } else {
            referenceTracker = nil
            referenceName = nil
        }
        reference = nil
        sessionToken = UUID()
        localPaused = false
        pendingPriorityCues.removeAll()
        partialCoachLine = nil
        log(.info, "Reprise : l'app s'était arrêtée pendant \(gap < 60 ? "\(Int(gap)) s" : Formatters.humanDuration(gap)).")

        // Chrono : encore en cours, on le relance pour le temps qui reste ; sonné pendant la coupure, on passe la main.
        if let t = c.timer {
            timerWorkSeconds = t.workSeconds; timerRestSeconds = t.restSeconds; timerRepeatsLeft = t.repeatsLeft; timerPhaseIsWork = t.phaseIsWork
            let remaining = Int(t.endsAt.timeIntervalSinceNow.rounded())
            if remaining >= 3 {
                runTimerPhase(seconds: remaining, label: t.label, baseLabel: t.baseLabel, index: t.index)
            } else {
                log(.info, "Chrono « \(t.label) » sonné pendant la coupure.")
                timerRepeatsLeft = 0
                if planTitle != nil {
                    if planQueue.isEmpty {
                        log(.info, "Programme terminé : \(planTitle ?? "")")
                        planTitle = nil; planStep = nil; planIndex = 0; planTotal = 0
                    } else {
                        pendingPlanAdvance = true
                    }
                }
            }
        }

        if UIApplication.shared.applicationState == .active {
            do { try audio.start() } catch {
                var tolerate = false
                #if DEBUG
                tolerate = FakeRealtimeBackend.enabled
                #endif
                if !tolerate {
                    errorMessage = "Audio : \(error.localizedDescription)"
                    phase = .idle
                    resuming = false
                    return
                }
            }
        }
        if !useAppleVoice, let cached = try? Data(contentsOf: ackFileURL), cached.count > 4_800 { ackAudio = cached }
        connectRealtime()
        adoptOrStartLiveActivity()
        saveCheckpoint()
        let token = sessionToken
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.sessionToken == token, self.phase == .connecting, !self.waitingForForeground else { return }
            self.errorMessage = self.errorMessage ?? "Connexion au coach impossible (délai dépassé)."
            self.stop(reason: "coach injoignable après 25 s (\(self.errorMessage ?? ""))")
        }
        sendMirror(force: true)
    }

    /// Journal complet de la séance (échanges + événements internes horodatés) dans Documents/derniere-seance.txt :
    /// lisible depuis Fichiers ou Xcode, c'est la trace de ce que Jeffrey a vu et dit.
    static let journalURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("derniere-seance.txt")
    /// Un fichier par séance dans Documents/journaux (les 30 derniers), pour retrouver une séance précise après coup.
    static let journalsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("journaux", isDirectory: true)

    private func writeSessionJournal() {
        guard let first = transcript.first else { return }
        let start = sessionStartedAt ?? latest?.sessionStart ?? first.at
        var lines = ["Séance \(kind.coachLabel) · \(start.formatted(date: .abbreviated, time: .shortened)) · mode \(mode == .owned ? "piloté" : "compagnon") · \(config.usesAppleAI ? "Apple AI" : "Jeffrey AI (\(config.model))") · montre \(connectivity.diagnostic)", ""]
        for l in transcript {
            let t = Int(max(0, l.at.timeIntervalSince(start)))
            let who: String
            switch l.role { case .user: who = "Lui"; case .coach: who = "Jeffrey"; case .info: who = "·" }
            lines.append(String(format: "%02d:%02d  %@  %@", t / 60, t % 60, who, l.text))
        }
        let text = lines.joined(separator: "\n")
        try? text.write(to: Self.journalURL, atomically: true, encoding: .utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.journalsDirectory, withIntermediateDirectories: true)
        let stamp = start.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")
        try? text.write(to: Self.journalsDirectory.appendingPathComponent("seance-\(stamp).txt"), atomically: true, encoding: .utf8)
        if let files = try? fm.contentsOfDirectory(at: Self.journalsDirectory, includingPropertiesForKeys: nil) {
            for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).dropLast(30) { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - Realtime

    /// Ouvre le WebSocket Realtime avec le justificatif du moment : jeton éphémère du compte Jeffrey (demandé au
    /// backend, quelques centaines de ms) ou clé perso. Un refus (accès en attente, quota) arrête la séance avec le motif.
    /// Le cerveau du jour : Apple AI (sur l'iPhone) ou OpenAI ; les callbacks sont rebranchés sur le nouveau lien.
    private func selectLink() {
        let wantsApple = config.usesAppleAI
        let isApple = realtime is AppleCoachLink
        if wantsApple != isApple {
            realtime.disconnect()
            realtime = wantsApple ? AppleCoachLink() : RealtimeClient()
            wireRealtime()
            audio.onCapturedPCM16 = { [weak self] data in self?.realtime.appendAudio(data) }
        }
    }

    private func connectRealtime() {
        if config.usesAppleAI { realtime.connect(apiKey: "", model: "apple", sessionConfig: sessionConfig()); return }
        #if DEBUG
        if FakeRealtimeBackend.enabled { realtime.connect(apiKey: config.apiKey, model: config.model, sessionConfig: sessionConfig()); return }
        #endif
        let token = sessionToken
        Task { [weak self] in
            guard let self else { return }
            do {
                let access = try await OpenAIAccess.realtimeCredential()
                guard self.sessionToken == token, self.phase == .connecting || self.phase == .live else { return }
                self.realtime.connect(apiKey: access.credential, model: access.model ?? self.config.model, sessionConfig: self.sessionConfig())
            } catch {
                guard self.sessionToken == token, self.phase == .connecting || self.phase == .live else { return }
                self.errorMessage = error.localizedDescription
                self.log(.info, "Accès OpenAI refusé : \(error.localizedDescription)")
                self.stop(reason: "accès OpenAI refusé")
            }
        }
    }

    /// Administrateur de l'app : Jeffrey a accès à son propre journal de séance et peut être interrogé dessus.
    var isAdminUser: Bool { AccountStore.shared.user?.isAdmin == true }

    /// Outil réservé à l'administrateur : lecture du journal de la séance en cours.
    private var sessionLogTool: [String: Any] {
        [
            "type": "function",
            "name": "get_session_log",
            "description": "Lire ton propre journal de séance (l'utilisateur est administrateur de l'application). À appeler dès qu'il te demande de regarder les logs, ce qui s'est passé, pourquoi tu n'as pas répondu, ce qu'il a dit, quand un chrono a sonné, l'état de la montre ou de la connexion. Renvoie un instantané de la séance (connexion, montre, reconnexions, dernières métriques) et des lignes horodatées mm:ss depuis le départ. Réponds avec les faits et les horodatages, sans te justifier.",
            "parameters": [
                "type": "object",
                "properties": [
                    "scope": ["type": "string", "enum": ["events", "errors", "tools", "watch", "dialogue", "all"], "description": "events = journal technique (défaut) ; errors = erreurs, pertes de connexion, refus ; tools = tes appels d'outils ; watch = montre et métriques ; dialogue = ce qu'il a dit et ce que tu as dit ; all = tout"],
                    "query": ["type": "string", "description": "Mot-clé pour filtrer les lignes (insensible à la casse)"],
                    "since_minutes": ["type": "number", "description": "Ne garder que les N dernières minutes"],
                    "count": ["type": "integer", "description": "Nombre maximal de lignes, 20 par défaut, 60 au plus"],
                ],
            ],
        ]
    }

    private func sessionConfig() -> [String: Any] {
        var cfg = baseSessionConfig()
        if isAdminUser {
            cfg["tools"] = ((cfg["tools"] as? [[String: Any]]) ?? []) + [sessionLogTool]
        }
        return cfg
    }

    private func baseSessionConfig() -> [String: Any] {
        [
            "type": "realtime",
            "instructions": config.instructions(kind: kind, mode: mode, sessionGoal: goal.coachLabel(), admin: isAdminUser),
            "output_modalities": [useAppleVoice ? "text" : "audio"],
            "tools": [[
                "type": "function",
                "name": "start_timer",
                "description": "Lancer le chronomètre de l'application. L'app sonne et te prévient quand il se termine ; tu n'as pas besoin de compter. Pour un fractionné, indique work_seconds, rest_seconds et repeats : l'app enchaîne travail et récupération et te prévient à chaque changement.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "seconds": ["type": "integer", "description": "Durée du bloc en secondes (ou du bloc de travail si repeats > 1)"],
                        "label": ["type": "string", "description": "Nom court du bloc (sprint, récup, plateau…)"],
                        "rest_seconds": ["type": "integer", "description": "Durée de récupération entre répétitions, 0 si aucune"],
                        "repeats": ["type": "integer", "description": "Nombre de répétitions, 1 par défaut"],
                    ],
                    "required": ["seconds", "label"],
                ],
            ], [
                "type": "function",
                "name": "suggest_workouts",
                "description": "Quand l'utilisateur demande des exercices, une idée de séance ou un programme : renvoie deux séances types adaptées au sport en cours et à un niveau. Le niveau connu de son profil est renvoyé (known_level) ; si l'utilisateur n'a rien précisé, demande-lui d'abord en une question courte s'il veut « comme d'habitude, plus doux ou plus costaud », puis appelle avec le niveau choisi. Présente ensuite les deux options à l'oral, une phrase chacune, et laisse-le choisir.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "level": ["type": "string", "enum": ["beginner", "amateur", "confirmed"], "description": "Niveau voulu ; omis = niveau du profil"],
                    ],
                ],
            ], [
                "type": "function",
                "name": "start_workout",
                "description": "Lancer une séance type choisie à l'oral (id renvoyé par suggest_workouts). L'app enchaîne les blocs avec le chronomètre et te prévient à chaque changement ; tu annonces chaque bloc et sa consigne. Rien à faire sur le téléphone.",
                "parameters": [
                    "type": "object",
                    "properties": ["id": ["type": "string"]],
                    "required": ["id"],
                ],
            ], [
                "type": "function",
                "name": "cancel_timer",
                "description": "Arrêter le chronomètre en cours (et le programme s'il y en a un).",
                "parameters": ["type": "object", "properties": [:]],
            ], [
                "type": "function",
                "name": "get_time",
                "description": "Lire l'heure exacte de la séance : temps écoulé, temps ou distance restants sur l'objectif, chronomètre en cours.",
                "parameters": ["type": "object", "properties": [:]],
            ], [
                "type": "function",
                "name": "end_session",
                "description": "Terminer la séance pour de bon (l'app arrête tout : montre, chrono, bilan). Toi seul déclenches la fin, et uniquement après confirmation orale : à « stop », « on arrête », « termine », demande d'abord « Je termine la séance ? » ; à son oui, appelle avec confirmed=true. Ne dis jamais que la séance est terminée sans cet appel.",
                "parameters": [
                    "type": "object",
                    "properties": ["confirmed": ["type": "boolean", "description": "true seulement après son oui explicite"]],
                    "required": ["confirmed"],
                ],
            ], [
                "name": "save_note",
                "description": "Enregistrer une note demandée par l'utilisateur : kind=memory pour un fait durable sur lui (blessure, objectif, préférence) que tu dois retenir aux prochaines séances ; kind=feedback pour une remarque ou un bug destinés au développeur de l'application. Confirme oralement en une phrase après l'appel.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": ["memory", "feedback"]],
                        "text": ["type": "string", "description": "La note, une ou deux phrases, à la troisième personne pour memory"],
                    ],
                    "required": ["kind", "text"],
                ],
            ], [
                "type": "function",
                "name": "set_goal",
                "description": "Changer l'objectif de la séance en cours (raccourcir, allonger, passer en libre) après accord ORAL de l'utilisateur. Demande d'abord en une question courte (« on passe à 25 minutes ? »), et appelle cette fonction quand il a dit oui. Le changement s'applique immédiatement, rien à faire sur le téléphone.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": ["duration", "distance", "free"]],
                        "target": ["type": "number", "description": "Minutes si kind=duration, kilomètres si kind=distance, 0 si free"],
                        "reason": ["type": "string", "description": "Pourquoi, en une phrase courte"],
                    ],
                    "required": ["kind", "target", "reason"],
                ],
            ], [
                "type": "function",
                "name": "show_on_watch",
                "description": "Choisir ce que la montre affiche en grand. what=zone avec zone 1-5 : jauge de fréquence cardiaque avec la zone à tenir (« reste en zone 2 »). what=pace avec pace « 5:30 » : allure cible et écart en direct (« vise 5 min 30 au kilo »). what=message avec text : ta phrase en grand quelques secondes (consigne importante, encouragement fort). what=clear : retour à l'écran normal quand la consigne ne tient plus. Le chrono, les montées, l'objectif atteint et le parcours fantôme s'affichent tout seuls, tu n'as rien à faire pour eux.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "what": ["type": "string", "enum": ["zone", "pace", "message", "clear"]],
                        "zone": ["type": "integer", "description": "1 à 5, pour what=zone"],
                        "pace": ["type": "string", "description": "m:ss par km, pour what=pace"],
                        "tolerance_seconds": ["type": "number", "description": "Marge autour de l'allure cible, 10 par défaut"],
                        "text": ["type": "string", "description": "Pour what=message, 90 caractères max"],
                        "seconds": ["type": "number", "description": "Durée d'affichage du message, 8 par défaut"],
                    ],
                    "required": ["what"],
                ],
            ], [
                "type": "function",
                "name": "remind_me",
                "description": "Rappel unique demandé par l'utilisateur : « préviens-moi dans 5 minutes », « dis-moi quand ça fait 30 secondes que je marche ». L'app compte (le décompte ne tourne que pendant l'activité visée et repart de zéro s'il en change) et te relance à l'échéance ; confirme en une phrase courte et n'annonce rien avant d'être relancé. Pour un bloc d'effort avec bip, préfère start_timer.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "seconds": ["type": "integer", "description": "Délai, de 5 à 3600 s"],
                        "while_activity": ["type": "string", "enum": ["any", "walking", "running", "stationary"], "description": "any pour un simple délai ; sinon le décompte ne tourne que tant qu'il est dans cette activité"],
                        "reason": ["type": "string", "description": "Ce que tu diras au déclenchement, en quelques mots"],
                    ],
                    "required": ["seconds", "while_activity", "reason"],
                ],
            ]],
            "tool_choice": "auto",
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    // Fin de phrase détectée au sens (il finit son idée avant qu'on réponde) ; la réponse est demandée
                    // par l'app une fois le texte reçu, pour ignorer le souffle, le vent et les mots isolés.
                    "turn_detection": [
                        "type": "semantic_vad",
                        "eagerness": "low",
                        "create_response": false,
                        "interrupt_response": false,
                    ],
                    "transcription": ["model": "gpt-4o-mini-transcribe", "language": "fr"],
                ],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "voice": config.voice,
                    "speed": NSDecimalNumber(string: "1.05"),
                ],
            ],
        ]
    }

    private func wireRealtime() {
        realtime.callbacks.onReady = { [weak self] in
            Task { @MainActor in self?.onRealtimeReady() }
        }
        realtime.callbacks.onAudioDelta = { [weak self] data in
            guard let self else { return }
            Task { @MainActor in
                self.lastAudioDeltaAt = Date()
                if self.capturingAck {
                    self.ackCaptureBuffer.append(data)
                } else {
                    self.audio.enqueuePlayback(pcm16: data)
                    if !self.coachSpeaking { self.coachSpeaking = true }
                }
            }
        }
        realtime.callbacks.onAssistantTranscriptDelta = { [weak self] delta in
            Task { @MainActor in self?.appendCoachDelta(delta) }
        }
        realtime.callbacks.onAssistantTranscriptDone = { [weak self] full in
            Task { @MainActor in self?.finishCoachLine(full) }
        }
        realtime.callbacks.onUserTranscript = { [weak self] text in
            Task { @MainActor in self?.handleUserTranscript(text) }
        }
        realtime.callbacks.onSpeechStarted = { [weak self] in
            // Pas d'interruption : Jeffrey finit sa phrase, la réponse à ce que tu dis arrive ensuite.
            Task { @MainActor in self?.userSpeaking = true }
        }
        realtime.callbacks.onSpeechStopped = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.userSpeaking = false
                self.lastUserSpokeAt = Date()
                self.scheduleAckIfSlow()
            }
        }
        realtime.callbacks.onResponseStarted = { [weak self] in
            Task { @MainActor in
                self?.responseInProgress = true
                if let e = self?.errorMessage, e.hasPrefix("Envoi") { self?.errorMessage = nil }
            }
        }
        realtime.callbacks.onResponseDone = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.responseInProgress = false
                if self.capturingAck {
                    self.capturingAck = false
                    let saidIt = (self.lastCoachLine ?? "").lowercased().contains("regarde")
                    if self.ackCaptureBuffer.count > 4_800, self.ackCaptureBuffer.count < 24_000 * 2 * 4, saidIt {
                        self.ackAudio = self.ackCaptureBuffer
                        try? self.ackCaptureBuffer.write(to: self.ackFileURL, options: .atomic)
                    }
                    self.ackCaptureBuffer = Data()
                    if self.pendingGreeting { self.pendingGreeting = false; self.sendGreeting() }
                    return
                }
                if self.useAppleVoice {
                    if self.phase == .ending, !self.appleVoice.isSpeaking { self.finishTeardown() }
                    else { self.replayPriorityCues() }
                } else {
                    self.scheduleSpeakingReset()
                    if self.phase == .ending { self.scheduleTeardownAfterPlayback() }
                }
            }
        }
        realtime.callbacks.onTextDelta = { [weak self] delta in
            Task { @MainActor in self?.handleTextDelta(delta) }
        }
        realtime.callbacks.onTextDone = { [weak self] full in
            Task { @MainActor in self?.handleTextDone(full) }
        }
        realtime.callbacks.onFunctionCall = { [weak self] name, callId, arguments in
            Task { @MainActor in self?.handleFunctionCall(name: name, callId: callId, arguments: arguments) }
        }
        realtime.callbacks.onError = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                // Ligne [MÉTRIQUES] déjà purgée côté serveur : sans conséquence.
                if message.contains("Error deleting item") { return }
                self.errorMessage = message
                self.log(.info, "Erreur : \(message)")
                if self.capturingAck {
                    self.capturingAck = false
                    self.ackCaptureBuffer = Data()
                    if self.pendingGreeting { self.pendingGreeting = false; self.sendGreeting() }
                }
            }
        }
        realtime.callbacks.onDisconnected = { [weak self] reason in
            Task { @MainActor in self?.handleDisconnect(reason) }
        }
    }

    /// Mode voix Apple : le texte de Jeffrey est lu phrase par phrase dès qu'il arrive.
    private func handleTextDelta(_ delta: String) {
        guard useAppleVoice else { return }
        if capturingAck { return }
        appendCoachDelta(delta)
        textResponseBuffer += delta
        sentenceBuffer += delta
        // Fin de phrase : on envoie à la synthèse sans attendre la suite.
        if let range = sentenceBuffer.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?…"), options: .backwards) {
            let end = range.upperBound
            let sentence = String(sentenceBuffer[..<end])
            let rest = String(sentenceBuffer[end...])
            if sentence.count >= 2 {
                sentenceBuffer = rest
                speakApple(sentence)
            }
        }
    }

    private func handleTextDone(_ full: String) {
        guard useAppleVoice else { return }
        if capturingAck { return }
        let tail = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { speakApple(tail) }
        sentenceBuffer = ""
        finishCoachLine(full.isEmpty ? textResponseBuffer : full)
        textResponseBuffer = ""
    }

    private func speakApple(_ text: String) {
        lastAudioDeltaAt = Date()
        coachSpeaking = true
        appleVoice.enqueue(text)
    }

    private func handleFunctionCall(name: String, callId: String, arguments: String) {
        let json = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        if name == "get_session_log" {
            guard isAdminUser else {
                realtime.sendFunctionOutput(callId: callId, output: ["error": "réservé à l'administrateur"])
                return
            }
            realtime.sendFunctionOutput(callId: callId, output: sessionLogReport(json))
            return
        }
        // Journal : chaque appel d'outil est tracé (l'administrateur peut interroger Jeffrey dessus).
        if name != "get_time" { log(.info, "Outil \(name)" + (json.isEmpty ? "" : " " + Self.compactArguments(json))) }
        if name == "end_session" {
            let confirmed = (json["confirmed"] as? Bool) ?? false
            guard confirmed else {
                realtime.sendFunctionOutput(callId: callId, output: ["ended": false, "hint": "demande-lui de confirmer en une question, puis rappelle avec confirmed=true"])
                return
            }
            log(.info, "Fin de séance demandée à l'oral et confirmée.")
            realtime.sendFunctionOutput(callId: callId, output: ["ended": true], thenRespond: false)
            stop(reason: "fin demandée à l'oral (end_session)")
            return
        }
        if name == "get_time" {
            realtime.sendFunctionOutput(callId: callId, output: timeStatus())
            return
        }
        if name == "cancel_timer" {
            cancelTimer()
            realtime.sendFunctionOutput(callId: callId, output: ["cancelled": true])
            return
        }
        if name == "show_on_watch" {
            handleShowOnWatch(callId: callId, json: json)
            return
        }
        if name == "remind_me" {
            let seconds = min(3600, max(5, (json["seconds"] as? Int) ?? Int((json["seconds"] as? Double) ?? 60)))
            let raw = json["while_activity"] as? String ?? "any"
            let target: ActivityMonitor.Activity? = raw == "any" ? nil : ActivityMonitor.Activity(rawValue: raw)
            let reason = (json["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            reminders.append(Reminder(seconds: TimeInterval(seconds), activity: target, reason: reason.isEmpty ? "rappel demandé" : reason, createdAt: Date()))
            let scope = target.map { " tant qu'il est en \($0.label)" } ?? ""
            log(.info, "Rappel dans \(seconds) s\(scope) : \(reason)")
            var out = timeStatus()
            out["scheduled"] = true
            out["seconds"] = seconds
            out["while_activity"] = raw
            realtime.sendFunctionOutput(callId: callId, output: out)
            return
        }
        if name == "start_timer" {
            let seconds = min(4 * 3600, max(5, (json["seconds"] as? Int) ?? Int((json["seconds"] as? Double) ?? 30)))
            let label = (json["label"] as? String ?? "bloc").trimmingCharacters(in: .whitespaces)
            let rest = max(0, (json["rest_seconds"] as? Int) ?? 0)
            let repeats = max(1, (json["repeats"] as? Int) ?? 1)
            startTimer(seconds: seconds, label: label, rest: rest, repeats: repeats)
            var out = timeStatus()
            out["started"] = true
            realtime.sendFunctionOutput(callId: callId, output: out)
            return
        }
        if name == "suggest_workouts" {
            let level = (json["level"] as? String).flatMap(AthleteLevel.init(rawValue:)) ?? config.level
            let list = WorkoutLibrary.workouts(kind: kind, level: level).prefix(2).map(\.toolPayload)
            log(.info, "Séances proposées (\(level.label)) : " + list.compactMap { $0["title"] as? String }.joined(separator: ", "))
            realtime.sendFunctionOutput(callId: callId, output: [
                "known_level": config.level.rawValue, "level": level.rawValue, "sport": kind.coachLabel, "workouts": list,
            ])
            return
        }
        if name == "start_workout" {
            guard let id = json["id"] as? String, let w = WorkoutLibrary.workout(id: id) else {
                realtime.sendFunctionOutput(callId: callId, output: ["error": "séance inconnue, rappelle suggest_workouts"])
                return
            }
            startWorkout(w)
            var out = timeStatus()
            out["started"] = true
            out["first_block"] = planQueue.isEmpty ? timerLabel ?? "" : "\(timerLabel ?? "") puis \(planQueue.first?.summary ?? "")"
            realtime.sendFunctionOutput(callId: callId, output: out)
            return
        }
        if name == "save_note" {
            let json = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
            let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = json["kind"] as? String ?? "feedback"
            guard !text.isEmpty else { realtime.sendFunctionOutput(callId: callId, output: ["error": "note vide"]); return }
            if kind == "memory" {
                JeffreyMemory.shared.add(text)
                log(.info, "Note mémorisée : \(text)")
            } else {
                DeveloperFeedback.append(text, context: metricsLine(prefix: ""))
                log(.info, "Retour développeur noté : \(text)")
            }
            realtime.sendFunctionOutput(callId: callId, output: ["saved": true, "kind": kind])
            return
        }
        guard name == "set_goal",
              let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kindRaw = json["kind"] as? String, let kind = SessionGoal.Kind(rawValue: kindRaw) else {
            realtime.sendFunctionOutput(callId: callId, output: ["error": "arguments invalides"])
            return
        }
        let value = (json["target"] as? Double) ?? 0
        let target: Double = kind == .duration ? value * 60 : (kind == .distance ? value * 1000 : 0)
        let reason = json["reason"] as? String ?? ""
        goal = SessionGoal(kind: kind, target: target, note: reason)
        goalReached = false
        let p = goal.progress(elapsed: liveElapsed(), distance: displayDistance)
        halfwayAnnounced = p.fraction >= 0.5
        log(.info, "Nouvel objectif : \(goal.label)\(reason.isEmpty ? "" : " · \(reason)")")
        sendMirror(force: true)
        realtime.sendFunctionOutput(callId: callId, output: ["applied": true, "goal": goal.coachLabel(), "remaining": p.remaining ?? "atteint"])
    }

    // MARK: - Chronomètre piloté par Jeffrey

    private func timeStatus() -> [String: Any] {
        var out: [String: Any] = [
            "elapsed": Formatters.elapsed(liveElapsed()),
            "clock": Date().formatted(date: .omitted, time: .shortened),
        ]
        if goal.kind != .free {
            let p = goal.progress(elapsed: liveElapsed(), distance: displayDistance)
            out["goal"] = goal.coachLabel()
            out["goal_remaining"] = p.remaining ?? "atteint"
        }
        if let label = timerLabel, let end = timerEndsAt {
            out["timer"] = label
            out["timer_remaining_seconds"] = Int(max(0, end.timeIntervalSinceNow))
        }
        if let planTitle {
            out["workout"] = planTitle
            out["workout_step"] = planStep ?? ""
            if let next = planQueue.first { out["workout_next_block"] = next.summary }
        }
        if activity.activity != .unknown {
            out["activity"] = activity.activity.rawValue
            out["activity_held_seconds"] = Int(Date().timeIntervalSince(activity.activitySince))
        }
        if !reminders.isEmpty {
            let now = Date()
            out["reminders"] = reminders.map { r -> [String: Any] in
                ["reason": r.reason, "while_activity": r.activity?.rawValue ?? "any",
                 "remaining_seconds": Int(max(0, r.seconds - heldSeconds(for: r, at: now)))]
            }
        }
        return out
    }

    // MARK: - Rappels demandés à l'oral

    /// Temps déjà tenu : depuis la demande, ou depuis le début de l'activité visée si elle a commencé après.
    private func heldSeconds(for r: Reminder, at now: Date) -> TimeInterval {
        guard let target = r.activity else { return now.timeIntervalSince(r.createdAt) }
        guard activity.activity == target else { return 0 }
        return now.timeIntervalSince(max(activity.activitySince, r.createdAt))
    }

    /// Chaque seconde : un rappel échu relance Jeffrey (en priorité, rejoué si quelqu'un parle).
    private func checkReminders() {
        guard phase == .live, !reminders.isEmpty, !isPaused else { return }
        let now = Date()
        for index in reminders.indices.reversed() where heldSeconds(for: reminders[index], at: now) >= reminders[index].seconds {
            let r = reminders.remove(at: index)
            log(.info, "Rappel : \(r.reason)")
            realtime.injectText("[RAPPEL] échéance demandée par l'utilisateur : \(r.reason). " + metricsLine(prefix: "[MÉTRIQUES]"))
            realtime.requestResponse(instructions: "Le rappel « \(r.reason) » vient de tomber : dis-le lui en une phrase et donne la suite.")
        }
    }

    // MARK: - Programme de séance (catalogue)

    func startWorkout(_ w: Workout) {
        cancelTimer()
        planTitle = w.title
        planQueue = w.blocks
        planTotal = w.blocks.count
        planIndex = 0
        if goal.kind == .free {
            goal = SessionGoal(kind: .duration, target: Double(w.totalSeconds), note: w.title)
            goalReached = false
            halfwayAnnounced = false
        }
        log(.info, "Programme : \(w.title) (\(w.summary))")
        startNextPlanBlock()
    }

    private func startNextPlanBlock() {
        guard !planQueue.isEmpty else { return }
        let block = planQueue.removeFirst()
        planIndex += 1
        planStep = "bloc \(planIndex)/\(planTotal)"
        startTimer(seconds: block.seconds, label: block.label, rest: block.restSeconds, repeats: block.repeats, keepPlan: true)
    }

    func startTimer(seconds: Int, label: String, rest: Int = 0, repeats: Int = 1, keepPlan: Bool = false) {
        if keepPlan { stopTimer() } else { cancelTimer() }
        timerWorkSeconds = seconds
        timerRestSeconds = rest
        timerRepeatsLeft = repeats
        timerPhaseIsWork = true
        runTimerPhase(seconds: seconds, label: repeats > 1 ? "\(label) 1/\(repeats)" : label, baseLabel: label, index: 1)
    }

    private func runTimerPhase(seconds: Int, label: String, baseLabel: String, index: Int) {
        timerLabel = label
        timerBaseLabel = baseLabel
        timerIndex = index
        timerEndsAt = Date().addingTimeInterval(TimeInterval(seconds))
        log(.info, "Chrono : \(label), \(seconds) s")
        sendMirror(force: true)
        timerTask = Task { [weak self] in
            // Rappel à 10 s de la fin pour les blocs longs.
            if seconds >= 45 {
                try? await Task.sleep(nanoseconds: UInt64(seconds - 10) * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.beep(short: true)
                self.realtime.injectText("[CHRONO] plus que 10 s sur « \(label) ».")
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            } else {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.beep(short: false)
            self.timerPhaseFinished(baseLabel: baseLabel, index: index)
        }
    }

    private func timerPhaseFinished(baseLabel: String, index: Int) {
        let finished = timerLabel ?? baseLabel
        timerLabel = nil
        timerEndsAt = nil
        if timerPhaseIsWork, timerRepeatsLeft > 1, timerRestSeconds == 0 {
            // Répétitions enchaînées sans récupération.
            timerRepeatsLeft -= 1
            let total = timerRepeatsLeft + index
            realtime.injectText("[CHRONO terminé] « \(finished) ». Répétition \(index + 1)/\(total) qui démarre tout de suite.")
            realtime.requestResponse(instructions: "Le bloc vient de sonner : enchaîne la répétition \(index + 1) sur \(total) en une phrase.")
            runTimerPhase(seconds: timerWorkSeconds, label: "\(baseLabel) \(index + 1)/\(total)", baseLabel: baseLabel, index: index + 1)
            return
        }
        if timerPhaseIsWork, timerRepeatsLeft > 1, timerRestSeconds > 0 {
            // Travail terminé → récupération
            timerPhaseIsWork = false
            realtime.injectText("[CHRONO terminé] « \(finished) ». Récupération de \(timerRestSeconds) s qui démarre.")
            realtime.requestResponse(instructions: "Le chrono « \(finished) » vient de sonner : annonce la fin du bloc et lance la récupération de \(timerRestSeconds) s en une phrase.")
            runTimerPhase(seconds: timerRestSeconds, label: "récup \(index)/\(timerRepeatsLeft + index - 1)", baseLabel: baseLabel, index: index)
            return
        }
        if !timerPhaseIsWork {
            // Récupération terminée → répétition suivante
            timerPhaseIsWork = true
            timerRepeatsLeft -= 1
            let total = timerRepeatsLeft + index
            realtime.injectText("[CHRONO terminé] récupération. Répétition \(index + 1)/\(total) de « \(baseLabel) » (\(timerWorkSeconds) s) qui démarre.")
            realtime.requestResponse(instructions: "La récup est finie : lance la répétition \(index + 1) sur \(total) de « \(baseLabel) » en une phrase énergique.")
            runTimerPhase(seconds: timerWorkSeconds, label: "\(baseLabel) \(index + 1)/\(total)", baseLabel: baseLabel, index: index + 1)
            return
        }
        timerRepeatsLeft = 0
        if let planTitle {
            if let next = planQueue.first {
                let step = planIndex + 1
                realtime.injectText("[PROGRAMME « \(planTitle) »] bloc « \(finished) » terminé. Bloc \(step)/\(planTotal) qui démarre : \(next.summary). " + metricsLine(prefix: "[MÉTRIQUES]"))
                realtime.requestResponse(instructions: "Le bloc « \(finished) » vient de sonner : annonce le bloc suivant « \(next.label) » (\(next.summary)) et sa consigne d'intensité en une ou deux phrases.")
                startNextPlanBlock()
                return
            }
            let title = planTitle
            self.planTitle = nil
            planStep = nil
            planIndex = 0
            planTotal = 0
            log(.info, "Programme terminé : \(title)")
            celebrate("Programme terminé", subtitle: title)
            realtime.injectText("[PROGRAMME terminé] « \(title) », tous les blocs sont faits. " + metricsLine(prefix: "[MÉTRIQUES]"))
            realtime.requestResponse(instructions: "Le programme « \(title) » est terminé : félicite-le en une phrase et dis ce qu'on fait maintenant (retour au calme, fin de séance, ou continuer libre).")
            return
        }
        sendMirror(force: true)
        realtime.injectText("[CHRONO terminé] « \(finished) ». " + metricsLine(prefix: "[MÉTRIQUES]"))
        realtime.requestResponse(instructions: "Le chrono « \(finished) » vient de sonner : annonce-le et donne la consigne suivante en une ou deux phrases.")
    }

    /// Arrête le bloc en cours sans toucher au programme (enchaînement interne).
    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        timerLabel = nil
        timerEndsAt = nil
        timerRepeatsLeft = 0
    }

    /// Arrêt demandé (bouton, outil cancel_timer) : chrono et programme.
    func cancelTimer() {
        stopTimer()
        if !reminders.isEmpty { log(.info, "Rappels annulés.") }
        reminders.removeAll()
        if let planTitle { log(.info, "Programme arrêté : \(planTitle)") }
        planTitle = nil
        planStep = nil
        planQueue = []
        planIndex = 0
        planTotal = 0
        sendMirror(force: true)
    }

    /// Bip local (dans la file audio de Jeffrey) : court pour le rappel, double pour la fin.
    private func beep(short: Bool) {
        let rate = 24_000.0
        func tone(_ freq: Double, _ dur: Double) -> [Int16] {
            (0..<Int(rate * dur)).map { i in
                let t = Double(i) / rate
                let env = min(1, min(t / 0.01, (dur - t) / 0.03))
                return Int16(sin(2 * .pi * freq * t) * 0.6 * env * 32767)
            }
        }
        var samples = tone(880, short ? 0.12 : 0.15)
        if !short { samples += [Int16](repeating: 0, count: Int(rate * 0.08)) + tone(1320, 0.18) }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        if useAppleVoice {
            // La voix Apple n'utilise pas la file PCM : petit lecteur dédié.
            BeepPlayer.shared.play(pcm16: data)
        } else {
            audio.enqueuePlayback(pcm16: data)
        }
    }

    private func onRealtimeReady() {
        // Connexion établie : plus de délai à surveiller, même en attente de premier plan où la phase reste .connecting.
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        errorMessage = nil
        reconnectAttempts = 0
        coachSpeaking = false
        responseInProgress = false
        if phase == .connecting {
            #if DEBUG
            let audioRequired = !FakeRealtimeBackend.enabled
            #else
            let audioRequired = true
            #endif
            if !audio.isRunning, audioRequired {
                if UIApplication.shared.applicationState != .active {
                    // Réveillé par la montre : iOS refuse le micro en arrière-plan, on attend l'ouverture de l'app.
                    waitingForForeground = true
                    status = "Ouvre Jeffrey sur l'iPhone pour lancer la voix"
                    sendMirror(force: true)
                    return
                }
                do {
                    try audio.start()
                } catch {
                    errorMessage = "Audio : \(error.localizedDescription)"
                    stop(reason: "audio impossible à démarrer : \(error.localizedDescription)")
                    return
                }
            }
            phase = .live
            status = "Coach en ligne"
            log(.info, config.usesAppleAI ? "Coach connecté (Apple AI sur l'iPhone)." : "Coach connecté (\(config.model), voix \(config.voice)).")
            startTimers()
            sendMirror(force: true)
            if resuming {
                resuming = false
                sendResumeContext()
                return
            }
            realtime.injectText("La séance de \(kind.coachLabel) démarre maintenant. Objectif du jour : \(goal.coachLabel()). " + metricsLine(prefix: "[MÉTRIQUES]"))
            if useAppleVoice {
                sendGreeting()
            } else if let cached = try? Data(contentsOf: ackFileURL), cached.count > 4_800 {
                ackAudio = cached
                sendGreeting()
            } else {
                // Une seule fois par voix : Jeffrey enregistre « Je regarde. » avec sa voix, joué localement ensuite.
                capturingAck = true
                pendingGreeting = true
                ackCaptureBuffer = Data()
                realtime.requestResponse(instructions: "Dis uniquement, sur un ton naturel : « Je regarde. » Rien d'autre.")
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard let self, self.capturingAck else { return }
                    self.capturingAck = false
                    self.ackCaptureBuffer = Data()
                    if self.pendingGreeting { self.pendingGreeting = false; self.sendGreeting() }
                }
            }
        } else if phase == .live {
            status = "Coach reconnecté"
            // Reprise sans amnésie : les dernières répliques, l'objectif et le chrono en cours.
            let recent = transcript.filter { $0.role != .info }.suffix(20)
                .map { ($0.role == .user ? "Lui : " : "Toi : ") + $0.text }.joined(separator: "\n")
            var resume = "Reconnexion après une coupure réseau ; la séance continue sans changement. Objectif : \(goal.coachLabel())."
            if let label = timerLabel, let end = timerEndsAt { resume += " Chrono en cours « \(label) », \(Int(max(0, end.timeIntervalSinceNow))) s restantes." }
            if let planTitle { resume += " Programme « \(planTitle) » en cours, \(planStep ?? "")." }
            if !recent.isEmpty { resume += "\nDernières répliques :\n" + recent }
            realtime.injectText(resume + "\n" + metricsLine(prefix: "[MÉTRIQUES]"))
        }
    }

    /// Reprise après une mort de l'app : Jeffrey reçoit où on en était et dit qu'il est de retour, sans repartir de zéro.
    private func sendResumeContext() {
        let recent = transcript.filter { $0.role != .info }.suffix(20)
            .map { ($0.role == .user ? "Lui : " : "Toi : ") + $0.text }.joined(separator: "\n")
        var resume = "L'application s'est arrêtée quelques instants (coupure technique) et vient de redémarrer : la séance de \(kind.coachLabel) continue, elle a commencé il y a \(Formatters.humanDuration(liveElapsed())). Objectif : \(goal.coachLabel())."
        if let label = timerLabel, let end = timerEndsAt { resume += " Chrono en cours « \(label) », \(Int(max(0, end.timeIntervalSinceNow))) s restantes." }
        if let planTitle { resume += " Programme « \(planTitle) » en cours, \(planStep ?? "")." }
        var next: WorkoutBlock?
        if pendingPlanAdvance, let n = planQueue.first {
            next = n
            resume += " Un bloc a sonné pendant la coupure ; le bloc suivant « \(n.label) » (\(n.summary)) démarre maintenant."
        }
        if !recent.isEmpty { resume += "\nDernières répliques :\n" + recent }
        realtime.injectText(resume + "\n" + metricsLine(prefix: "[MÉTRIQUES]"))
        var ask = "Dis en une phrase que tu es de retour après une petite coupure, sans t'étendre, et reprends là où vous en étiez."
        if let next { ask += " Annonce le bloc « \(next.label) » (\(next.summary)) et sa consigne d'intensité." }
        realtime.requestResponse(instructions: ask)
        if pendingPlanAdvance {
            pendingPlanAdvance = false
            startNextPlanBlock()
        }
    }

    private func sendGreeting() {
        let name = config.userName.isEmpty ? "" : " Appelle-le \(config.userName)."
        if goal.isTrial {
            // Tour d'essai (onboarding) : on est chez soi, deux minutes pour faire connaissance et vérifier que tout marche.
            realtime.requestResponse(instructions: "C'est un tour d'essai de deux minutes, à la maison, pour vérifier que tout marche : présente-toi comme Jeffrey en une phrase chaleureuse.\(name) Explique qu'on ne sort pas, demande-lui de marcher quelques pas dans la pièce et de te dire un mot, tu confirmeras que tu l'entends et que la montre te donne son cœur. Une question courte à la fin.")
            return
        }
        let goalPart = goal.kind == .free ? "" : " Rappelle l'objectif en quelques mots."
        // Il sait qui parle : un « Salut Hervé » suffit, jamais « c'est Jeffrey » (retour du 20/09).
        realtime.requestResponse(instructions: "Salue-le par son prénom en une phrase chaleureuse, sans dire ton nom ni te présenter : il sait que c'est toi.\(name)\(goalPart) Puis pose une seule question courte : il fait sa séance à sa façon, ou tu lui proposes un exercice adapté ? S'il veut une proposition, suis la règle 10 (suggest_workouts). S'il préfère sa façon, lance la séance sans insister.")
    }

    /// Si aucune parole de Jeffrey n'arrive dans la seconde qui suit la fin de la tienne, on joue « Je regarde. ».
    private func scheduleAckIfSlow() {
        let stoppedAt = Date()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard let self, self.phase == .live else { return }
            // Seulement si le serveur a bien ouvert une réponse (vraie parole) et qu'aucun audio n'est encore arrivé.
            guard self.responseInProgress, self.lastAudioDeltaAt < stoppedAt, Date().timeIntervalSince(self.lastAckAt) > 8 else { return }
            if self.useAppleVoice {
                guard !self.appleVoice.isSpeaking else { return }
                self.lastAckAt = Date()
                self.speakApple("Je regarde.")
                return
            }
            guard let ack = self.ackAudio, !self.audio.isPlaying else { return }
            self.lastAckAt = Date()
            self.audio.enqueuePlayback(pcm16: ack)
            self.coachSpeaking = true
            self.scheduleSpeakingReset()
        }
    }

    private func handleDisconnect(_ reason: String) {
        // Plus rien ne parle ni ne répond : on libère les drapeaux, sinon Jeffrey reste muet.
        coachSpeaking = false
        responseInProgress = false
        audio.stopPlayback()
        if phase == .ending { finishTeardown(); return }
        guard phase == .live || phase == .connecting else { return }
        if config.usesAppleAI {
            // Rien à reconnecter : Apple AI s'arrête seulement s'il est indisponible.
            errorMessage = errorMessage ?? reason
            stop(reason: "Apple AI déconnecté : \(reason)")
            return
        }
        // Clé refusée ou accès interdit : inutile de retenter.
        if let err = errorMessage?.lowercased(), err.contains("api key") || err.contains("invalid_api_key") || err.contains("unauthorized") {
            errorMessage = "Clé API refusée par OpenAI : vérifie-la dans les réglages (elle commence par sk-)."
            stop(reason: "clé API refusée")
            return
        }
        reconnectAttempts += 1
        log(.info, "Connexion coach perdue (\(reason)), reconnexion \(reconnectAttempts)/5…")
        guard reconnectAttempts <= 5 else {
            errorMessage = "Connexion perdue : \(reason)"
            stop(reason: "5 reconnexions échouées (\(reason))")
            return
        }
        status = "Reconnexion (\(reconnectAttempts)/5)…"
        let delay = Double(reconnectAttempts) * 1.5
        let token = sessionToken
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.sessionToken == token, self.phase == .live || self.phase == .connecting else { return }
            self.connectRealtime()
        }
    }

    private func scheduleSpeakingReset() {
        Task { [weak self] in
            // On attend la fin de la lecture des tampons avant de passer coachSpeaking à false.
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                if !self.audio.isPlaying {
                    await MainActor.run { self.coachSpeaking = false; self.replayPriorityCues() }
                    return
                }
            }
            guard let self else { return }
            // Lecture bloquée (interruption audio) : on vide et on libère.
            self.audio.stopPlayback()
            self.coachSpeaking = false
            self.replayPriorityCues()
        }
    }

    private func scheduleTeardownAfterPlayback() {
        Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                if !self.audio.isPlaying { break }
            }
            self?.finishTeardown()
        }
    }

    // MARK: - Métriques → contexte

    private func handle(snapshot snap: MetricsSnapshot) {
        if snap.state == .paused || snap.state == .running {
            localPaused = snap.state == .paused
            gps.paused = localPaused
            activity.paused = localPaused
        }
        if let d = snap.distance {
            distanceHistory.append((snap.timestamp, d))
            distanceHistory.removeAll { snap.timestamp.timeIntervalSince($0.0) > 45 }
        }
        pace = computePace(snap)
        if let hr = snap.heartRate, snap.state == .running {
            hrSamples.append(hr)
            let now = snap.timestamp
            if let last = lastZoneSampleAt {
                let dt = Int(min(15, max(0, now.timeIntervalSince(last))))
                zoneSeconds[HeartRateZone.zone(for: hr, maxHR: config.maxHR).rawValue - 1] += dt
            }
            lastZoneSampleAt = now
        } else {
            lastZoneSampleAt = nil
        }
        if let hr = snap.heartRate {
            let zone = HeartRateZone.zone(for: hr, maxHR: config.maxHR)
            currentZone = zone
            if phase == .live, config.autoCues, let previous = lastAnnouncedZone, previous != zone,
               Date().timeIntervalSince(lastCueAt) > 45, Date().timeIntervalSince(lastEventCueAt) > 45, !isPaused,
               zone.rawValue >= 5 || (previous.rawValue >= 5 && zone.rawValue <= 3) {
                lastEventCueAt = Date()
                cue(reason: zone.rawValue >= 5 ? "FC en zone 5 (\(Int(hr)) bpm) : vérifier que c'est voulu, sinon lever le pied" : "FC redescendue de la zone 5 : bien récupéré")
            }
            if lastAnnouncedZone == nil { lastAnnouncedZone = zone }
        }
        evaluateGoal()
        if phase == .connecting, snap.state == .ended, Date().timeIntervalSince(watchdogFrom) > 5 {
            stop(reason: "la montre a envoyé « terminé » avant le début (état \(snap.state), instantané de \(Int(Date().timeIntervalSince(snap.timestamp))) s)")
            return
        }
        if phase == .live, snap.state == .ended {
            log(.info, mode == .owned ? "La montre a terminé la séance." : "La séance de l'app Exercice est terminée.")
            stop(reason: mode == .owned ? "la montre a terminé la séance" : "la séance de l'app Exercice est terminée")
        }
    }

    /// Distance affichée : montre en priorité, sinon GPS de l'iPhone.
    var displayDistance: Double? {
        if let d = latest?.distance, d > 0 { return d }
        return gps.distance > 20 ? gps.distance : nil
    }

    private func handle(location: CLLocation) {
        guard let tracker = referenceTracker, let start = gps.startedAt else { return }
        let status = tracker.update(location: location, elapsed: Date().timeIntervalSince(start))
        let previous = reference
        reference = status
        guard phase == .live, config.autoCues, !status.offRoute else { return }
        let now = Date()
        // Montée significative à venir : on prévient une fois, au plus toutes les 3 minutes.
        if status.gainNext >= 15, now.timeIntervalSince(lastClimbWarnAt) > 180, (previous?.gainNext ?? 0) < 15 || previous == nil {
            lastClimbWarnAt = now
            cue(reason: String(format: "montée à venir : +%.0f m sur 500 m (%.0f %%)", status.gainNext, status.gradeNext))
            return
        }
        // Fantôme : décrochage ou avance nette, au plus toutes les 4 minutes.
        if let g = status.ghostDelta, abs(g) >= 30, now.timeIntervalSince(lastGhostWarnAt) > 240 {
            lastGhostWarnAt = now
            cue(reason: g < 0 ? "retard de \(Int(-g)) s sur la séance de référence" : "avance de \(Int(g)) s sur la séance de référence")
        }
    }

    /// Allure courante en s/km, pour la scène allure de la montre.
    private func updatePaceNumber() {
        var v: Double? = latest?.speed
        if v == nil, latest?.distance == nil { v = gps.speed }
        if v == nil, let first = distanceHistory.first, let last = distanceHistory.last, last.0 > first.0 {
            let dt = last.0.timeIntervalSince(first.0), dd = last.1 - first.1
            if dt >= 10, dd > 5 { v = dd / dt }
        }
        currentPaceSecPerKm = (v ?? 0) > 0.3 ? 1000 / v! : nil
    }

    private func computePace(_ snap: MetricsSnapshot) -> String? {
        if let v = snap.speed, let p = Formatters.pace(speedMetersPerSecond: v) { return p }
        if snap.distance == nil, let v = gps.speed, let p = Formatters.pace(speedMetersPerSecond: v) { return p }
        guard let first = distanceHistory.first, let last = distanceHistory.last, last.0 > first.0 else { return nil }
        let dt = last.0.timeIntervalSince(first.0)
        let dd = last.1 - first.1
        guard dt >= 10, dd > 5 else { return nil }
        return Formatters.pace(speedMetersPerSecond: dd / dt)
    }

    private func metricsLine(prefix: String) -> String {
        let elapsedNow = liveElapsed()
        guard let s = latest else {
            var parts = ["\(prefix) temps écoulé \(Formatters.elapsed(elapsedNow)) · aucune donnée de la montre pour l'instant"]
            if kind.usesDistance, let d = displayDistance {
                parts.append("distance \(Formatters.distance(d)) (GPS iPhone)")
                if let v = gps.speed, let p = Formatters.pace(speedMetersPerSecond: v) { parts.append("allure \(p)") }
            }
            let act = activity.summaryLine()
            if !act.isEmpty { parts.append("corps/terrain : \(act)") }
            if goal.kind != .free {
                let p = goal.progress(elapsed: elapsedNow, distance: displayDistance)
                parts.append("objectif \(goal.coachLabel()) : \(Int(p.fraction * 100)) %\(p.remaining.map { ", \($0)" } ?? "")")
            }
            return parts.joined(separator: " · ")
        }
        var parts: [String] = ["temps écoulé \(Formatters.elapsed(elapsedNow))"]
        if let hr = s.heartRate {
            let zone = HeartRateZone.zone(for: hr, maxHR: config.maxHR)
            let pct = Int(hr / config.maxHR * 100)
            parts.append("FC \(Int(hr)) bpm (\(zone.label) \(zone.description), \(pct) % FCmax)")
        } else {
            parts.append("FC inconnue")
        }
        if s.kind.usesDistance {
            if let d = s.distance { parts.append("distance \(Formatters.distance(d))") }
            else if let d = displayDistance { parts.append("distance \(Formatters.distance(d)) (GPS iPhone)") }
            if let p = pace { parts.append("allure \(p)") }
        }
        if let e = s.activeEnergy { parts.append("\(Int(e)) kcal") }
        let act = activity.summaryLine()
        if !act.isEmpty { parts.append("corps/terrain : \(act)") }
        if goal.kind != .free {
            let p = goal.progress(elapsed: elapsedNow, distance: displayDistance)
            parts.append("objectif \(goal.coachLabel()) : \(Int(p.fraction * 100)) %\(p.remaining.map { ", \($0)" } ?? "")\(goalReached ? " · atteint, déjà annoncé, n'en reparle pas" : "")")
        }
        if let r = reference, let name = referenceName {
            if r.offRoute {
                parts.append("parcours de référence « \(name) » : hors tracé pour l'instant")
            } else {
                var ref = "parcours « \(name) » : \(r.progressText) · 500 m à venir : \(r.reliefText)"
                if let g = r.ghostText { ref += " · vs référence : \(g)" }
                parts.append(ref)
            }
        }
        if let label = timerLabel, let end = timerEndsAt { parts.append("chrono « \(label) » : \(Int(max(0, end.timeIntervalSinceNow))) s restantes") }
        if let planTitle { parts.append("programme « \(planTitle) » \(planStep ?? "")") }
        if s.state == .paused { parts.append("séance EN PAUSE") }
        if s.state == .ended { parts.append("séance terminée côté montre") }
        let age = Int(Date().timeIntervalSince(s.lastSampleAt ?? s.timestamp))
        parts.append("dernière mesure il y a \(age) s")
        return "\(prefix) " + parts.joined(separator: " · ")
    }

    private func startTimers() {
        stopTimers()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.injectMetricsIfChanged() }
        }
        goalTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.latest?.speed == nil, let v = self.gps.speed, !self.isPaused { self.pace = Formatters.pace(speedMetersPerSecond: v) }
                self.updatePaceNumber()
                self.evaluateGoal(); self.detectStruggle()
            }
        }
        mirrorTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendMirror() }
        }
        if config.autoCues {
            cueTimer = Timer.scheduledTimer(withTimeInterval: config.cueInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.routineCheck() }
            }
        }
        lastCueAt = Date()
    }

    private func stopTimers() {
        metricsTimer?.invalidate()
        cueTimer?.invalidate()
        goalTimer?.invalidate()
        mirrorTimer?.invalidate()
        metricsTimer = nil
        cueTimer = nil
        goalTimer = nil
        mirrorTimer = nil
    }

    /// Le temps avance même si la montre se tait : on injecte à intervalle fixe, données nouvelles ou non.
    private func injectMetricsIfChanged() {
        guard phase == .live, realtime.isConnected else { return }
        realtime.injectMetrics(metricsLine(prefix: "[MÉTRIQUES]"))
    }

    /// Montre obligatoire : plus de données depuis 2 min et montre injoignable → la séance s'arrête.
    private func watchWatchdog() {
        guard phase == .live, !isPaused else { return }
        let stale = latest.map { Date().timeIntervalSince($0.timestamp) > 120 } ?? (Date().timeIntervalSince(watchdogFrom) > 120)
        if stale, !connectivity.isReachable {
            errorMessage = "Montre perdue : séance arrêtée."
            stop(reason: "montre injoignable depuis plus de 2 minutes")
        }
    }

    /// Coaching de fond : Jeffrey reste présent, avec un contenu qui a une raison d'être (kilomètre, allure, technique, objectif).
    private func routineCheck() {
        guard phase == .live, !isPaused else { return }
        watchWatchdog()
        let now = Date()
        let silence = now.timeIntervalSince(max(lastCoachSpokeAt, lastCueAt))
        guard silence >= 30 else { return }

        // 1) Passage kilométrique : temps du dernier km, un vrai repère de coach.
        if let d = displayDistance, kind.usesDistance {
            let km = Int(d / 1000)
            if km > lastKmAnnounced {
                let split = lastKmAt.map { now.timeIntervalSince($0.at) }
                let splitText = split.map { " en \(Formatters.elapsed($0))" } ?? ""
                if cue(reason: "kilomètre \(km) passé\(splitText) : annonce-le, situe l'allure par rapport à l'objectif ou au ressenti, un mot d'encouragement") {
                    lastKmAnnounced = km
                    lastKmAt = (km, now)
                }
                return
            }
        }
        // 2) Zone haute qui change, longue montée sans galère détectée.
        if let hr = latest?.heartRate {
            let zone = HeartRateZone.zone(for: hr, maxHR: config.maxHR)
            if let last = lastCueZone, zone != last, zone.rawValue >= 4 || last.rawValue >= 4 {
                cue(reason: "zone cardiaque passée de \(last.label) à \(zone.label)")
                return
            }
        }
        if activity.terrain == .climb, now.timeIntervalSince(activity.terrainSince) > 60, !struggleAnnouncedForClimb, silence >= 60 {
            cue(reason: "longue montée en cours, il tient : soutien et repère (ça monte encore combien, respirer)")
            return
        }
        // 3) Coaching régulier : toutes les 2 min (présent) ou 4 min (discret), sujets en rotation.
        let interval: TimeInterval = config.presence == "discreet" ? 240 : 120
        guard silence >= interval else { return }
        let topics = [
            "point d'allure : comment il se situe par rapport à l'objectif, garder ou ajuster",
            "technique : relâchement des épaules, bras, regard loin, foulée légère (choisis un seul point)",
            "respiration et rythme : caler le souffle sur les pas, un repère simple",
            "encouragement sincère lié à ce qu'il fait maintenant (durée tenue, régularité, effort)",
            "récupération et hydratation si la séance dépasse 30 min, sinon un repère sur le temps restant",
        ]
        let topic = topics[routineTopic % topics.count]
        routineTopic += 1
        cue(reason: "coaching de fond (\(topic)) : une ou deux phrases, utiles, sans répéter les précédentes")
    }

    /// Galère en montée et dérive de fatigue : détection sur les historiques FC / allure.
    private func detectStruggle() {
        guard phase == .live, config.autoCues, !isPaused else { return }
        let now = Date()
        if let hr = latest?.heartRate { hrHistory.append((now, hr)) }
        if let v = gps.speed ?? latest?.speed { speedHistory.append((now, v)) }
        hrHistory.removeAll { now.timeIntervalSince($0.0) > 300 }
        speedHistory.removeAll { now.timeIntervalSince($0.0) > 300 }
        func avg(_ h: [(Date, Double)], from: TimeInterval, to: TimeInterval) -> Double? {
            let xs = h.filter { let a = now.timeIntervalSince($0.0); return a >= to && a <= from }.map(\.1)
            return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        }
        // Galère en montée : FC qui grimpe vite ou déjà très haute, allure ou cadence qui s'effondrent.
        if activity.terrain == .climb, !struggleAnnouncedForClimb, now.timeIntervalSince(activity.terrainSince) >= 20,
           now.timeIntervalSince(lastEventCueAt) >= 30 {
            let hrNow = avg(hrHistory, from: 15, to: 0)
            let hrBefore = avg(hrHistory, from: 60, to: 40)
            let vNow = avg(speedHistory, from: 20, to: 0)
            let vBefore = avg(speedHistory, from: 150, to: 60)
            let hrRising = (hrNow ?? 0) - (hrBefore ?? hrNow ?? 0) >= 8
            let hrHigh = hrNow.map { HeartRateZone.zone(for: $0, maxHR: config.maxHR).rawValue >= 5 } ?? false
            let slowing = (vNow ?? 1) < (vBefore ?? 0) * 0.7 && (vBefore ?? 0) > 1
            let cadenceDrop = activity.activity == .running && (activity.cadence ?? 999) < activity.typicalRunningCadence * 0.92
            if (hrRising && (slowing || cadenceDrop)) || hrHigh || (slowing && cadenceDrop) {
                struggleAnnouncedForClimb = true
                lastEventCueAt = now
                let detail = [hrHigh ? "FC en zone 5" : (hrRising ? "FC qui grimpe" : nil), slowing ? "allure qui chute" : nil, cadenceDrop ? "cadence qui tombe" : nil].compactMap { $0 }.joined(separator: ", ")
                cue(reason: "il galère dans la montée (\(detail)) : soutiens-le concrètement, foulée courte, bras, regard, autoriser à marcher si besoin")
                return
            }
        }
        // Dérive de fatigue sur le plat : FC nettement plus haute à allure égale sur 4 minutes.
        if activity.terrain == .flat, now.timeIntervalSince(fatigueAnnouncedAt) >= 600,
           let hrNow = avg(hrHistory, from: 30, to: 0), let hrBefore = avg(hrHistory, from: 270, to: 210),
           let vNow = avg(speedHistory, from: 30, to: 0), let vBefore = avg(speedHistory, from: 270, to: 210),
           hrNow - hrBefore >= 10, abs(vNow - vBefore) / max(vBefore, 0.1) < 0.1, vNow > 1 {
            fatigueAnnouncedAt = now
            lastEventCueAt = now
            cue(reason: "dérive cardiaque : FC +\(Int(hrNow - hrBefore)) bpm à allure égale depuis 4 min, signe de fatigue ou de chaleur : proposer de lever un peu le pied ou de boire")
        }
    }

    /// Évalue l'objectif sur le temps réel, indépendamment des messages de la montre.
    private func evaluateGoal() {
        guard phase == .live, goal.kind != .free else { return }
        let elapsed = liveElapsed()
        let p = goal.progress(elapsed: elapsed, distance: displayDistance)
        if !goalReached, goal.isReached(elapsed: elapsed, distance: displayDistance) {
            goalReached = true
            lastCueAt = .distantPast
            celebrate("Objectif atteint", subtitle: "\(goal.label) · \(Formatters.elapsed(elapsed))")
            if goal.isTrial {
                let hr = latest?.heartRate.map { " Sa montre t'a donné \(Int($0)) bpm." } ?? " La montre n'a pas encore envoyé de cœur : dis-le sans dramatiser."
                cue(reason: "fin du tour d'essai.\(hr) Dis en deux phrases que tout est prêt, que la prochaine fois ce sera dehors pour de vrai, et dis au revoir : la séance s'arrête toute seule")
                let token = sessionToken
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 14_000_000_000)
                    guard let self, self.sessionToken == token, self.phase == .live else { return }
                    self.stop(reason: "fin du tour d'essai")
                }
            } else if let planTitle {
                // Programme en cours : on félicite sans proposer d'arrêter, sinon Jeffrey dit « on s'arrête ? » puis
                // « allez, dernière minute de course » trois secondes plus tard (séance du 19/09).
                let left = planQueue.count + (timerLabel != nil ? 1 : 0)
                cue(reason: "objectif atteint : \(goal.coachLabel()). Félicite en une phrase, mais le programme « \(planTitle) » continue (encore \(left) bloc\(left > 1 ? "s" : "")) : ne propose pas d'arrêter, on le finit")
            } else {
                cue(reason: "objectif atteint : \(goal.coachLabel()). Félicite en une phrase ; la séance continue tant qu'il ne dit pas stop, ne parle pas de terminer")
            }
        } else if !halfwayAnnounced, p.fraction >= 0.5, config.goalCues, !goal.isTrial {
            if cue(reason: "mi-parcours de l'objectif (\(goal.coachLabel()))") { halfwayAnnounced = true }
        }
    }

    /// Interventions prioritaires : elles passent devant l'espacement (chrono, objectif atteint, galère, arrêt long).
    private func isPriority(_ reason: String) -> Bool {
        ["objectif atteint", "galère", "chrono", "arrêt depuis", "demande manuelle", "zone 5"].contains { reason.lowercased().contains($0) }
    }

    /// Les annonces prioritaires refusées (Jeffrey parlait) sont rejouées dès qu'il a fini.
    private func replayPriorityCues() {
        guard !pendingPriorityCues.isEmpty, phase == .live, !coachSpeaking, !responseInProgress else { return }
        let reason = pendingPriorityCues.removeFirst()
        _ = cue(reason: reason)
    }

    /// Demande une intervention courte du coach. Renvoie true si elle est envoyée ou mise en attente (prioritaire).
    @discardableResult
    func cue(reason: String) -> Bool {
        guard phase == .live, realtime.isConnected, !isPaused else { return false }
        if responseInProgress || userSpeaking || coachSpeaking {
            if isPriority(reason), !pendingPriorityCues.contains(reason) { pendingPriorityCues.append(reason); return true }
            return false
        }
        let now = Date()
        if !isPriority(reason) {
            // Conversation en cours avec l'utilisateur : on ne l'interrompt pas avec du spontané.
            guard now.timeIntervalSince(lastUserSpokeAt) >= 60 else { return false }
            // Silence minimal après la dernière phrase de Jeffrey.
            guard now.timeIntervalSince(lastCoachSpokeAt) >= 30 else { return false }
            // Espacement entre deux interventions spontanées.
            let spacing: TimeInterval = config.presence == "discreet" ? 180 : 90
            guard now.timeIntervalSince(lastSpontaneousCueAt) >= spacing else { return false }
            lastSpontaneousCueAt = now
        } else if now.timeIntervalSince(lastCoachSpokeAt) < 8 {
            if !pendingPriorityCues.contains(reason) { pendingPriorityCues.append(reason) }
            return true
        }
        lastCueAt = now
        if let hr = latest?.heartRate {
            lastAnnouncedZone = HeartRateZone.zone(for: hr, maxHR: config.maxHR)
            lastCueZone = lastAnnouncedZone
        }
        lastInjectedSnapshot = latest
        realtime.injectMetrics(metricsLine(prefix: "[MÉTRIQUES]"))
        realtime.requestResponse(instructions: "Intervention coach (\(reason)) : 1 à 2 phrases orales, utiles, sans répéter la précédente.")
        return true
    }

    /// Ce qu'il a dit, transcrit. Avec OpenAI, c'est l'app qui déclenche la réponse : le souffle, le vent et les mots
    /// isolés sans sens (« Schock », « Lemmonement ») sont ignorés au lieu de provoquer un « bravo » réflexe.
    private func handleUserTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let appleAI = realtime is AppleCoachLink
        if !appleAI, !Self.looksLikeSpeech(trimmed) {
            log(.info, "Bruit ignoré : « \(trimmed) »")
            return
        }
        log(.user, trimmed)
        lastUserSpokeAt = Date()
        if !appleAI { realtime.requestResponse() }
    }

    /// Deux mots au moins, ou un mot court attendu (oui, non, ok, stop…), en alphabet latin.
    static func looksLikeSpeech(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.unicodeScalars.contains(where: { $0.value > 0x24F && !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0) }) { return false }
        let words = lowered.split { !$0.isLetter && $0 != "'" }.map(String.init)
        if words.count >= 2 { return true }
        let short: Set<String> = ["oui", "non", "ok", "okay", "stop", "go", "merci", "d'accord", "vas-y", "pause", "reprends", "termine", "continue", "attends", "ouais", "nan", "encore"]
        return words.first.map { short.contains($0) } ?? false
    }

    // MARK: - Transcript

    private func appendCoachDelta(_ delta: String) {
        if var line = partialCoachLine {
            line.text += delta
            partialCoachLine = line
            if let idx = transcript.firstIndex(where: { $0.id == line.id }) { transcript[idx] = line }
        } else {
            let line = TranscriptLine(role: .coach, text: delta)
            partialCoachLine = line
            transcript.append(line)
        }
    }

    private func finishCoachLine(_ full: String) {
        if let line = partialCoachLine, let idx = transcript.firstIndex(where: { $0.id == line.id }), !full.isEmpty {
            transcript[idx].text = full
        }
        if let line = partialCoachLine { lastCoachLine = full.isEmpty ? line.text : full }
        partialCoachLine = nil
        lastCoachSpokeAt = Date()
        sendMirror(force: true)
    }

    // MARK: - Journal de séance pour l'administrateur

    /// Ce que Jeffrey lit quand l'administrateur l'interroge sur ses logs : instantané + lignes horodatées filtrées.
    func sessionLogReport(_ args: [String: Any]) -> [String: Any] {
        let scope = (args["scope"] as? String) ?? "events"
        let query = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let count = min(60, max(5, (args["count"] as? Int) ?? 20))
        let start = sessionStartedAt ?? Date()
        let since: Date? = (args["since_minutes"] as? Double).map { Date().addingTimeInterval(-$0 * 60) }
        let errorWords = ["erreur", "perdue", "refusé", "injoignable", "indisponible", "annulée", "interrompue", "bruit ignoré", "arrêt de la séance"]
        let watchWords = ["montre", "métrique", "exercice", "cœur", "bpm", "gps"]
        func matches(_ l: TranscriptLine) -> Bool {
            if let since, l.at < since { return false }
            let text = l.text.lowercased()
            if !query.isEmpty, !text.contains(query) { return false }
            switch scope {
            case "all": return true
            case "dialogue": return l.role != .info
            case "errors": return l.role == .info && errorWords.contains { text.contains($0) }
            case "tools": return l.role == .info && (text.hasPrefix("outil ") || text.hasPrefix("chrono") || text.hasPrefix("programme") || text.hasPrefix("rappel") || text.hasPrefix("nouvel objectif") || text.hasPrefix("note ") || text.hasPrefix("séances proposées"))
            case "watch": return l.role == .info && watchWords.contains { text.contains($0) }
            default: return l.role == .info
            }
        }
        func stamp(_ l: TranscriptLine) -> String {
            let t = Int(max(0, l.at.timeIntervalSince(start)))
            let who: String
            switch l.role { case .user: who = "LUI "; case .coach: who = "TOI "; case .info: who = "" }
            return String(format: "%02d:%02d %@%@", t / 60, t % 60, who, l.text)
        }
        let selected = transcript.filter(matches)
        let lines = selected.suffix(count).map(stamp)
        let errors = transcript.filter { l in l.role == .info && errorWords.contains { l.text.lowercased().contains($0) } }.suffix(10).map(stamp)
        let elapsed = Int(max(0, Date().timeIntervalSince(start)))
        var snapshot: [String: Any] = [
            "phase": String(describing: phase),
            "elapsed": String(format: "%02d:%02d", elapsed / 60, elapsed % 60),
            "started_at": DateFormatter.localizedString(from: start, dateStyle: .none, timeStyle: .short),
            "sport": kind.coachLabel, "capture": mode.label,
            "coach_link": config.usesAppleAI ? "Apple AI sur l'iPhone" : "Jeffrey AI (\(config.model))",
            "coach_connected": realtime.isConnected,
            "reconnections": reconnectAttempts,
            "watch": connectivity.linkLabel,
            "paused": isPaused,
            "goal": goal.label,
            "transcript_lines": transcript.count,
            "truncated": selected.count > lines.count,
        ]
        if let snap = latest {
            snapshot["last_metrics_age_s"] = Int(Date().timeIntervalSince(snap.timestamp))
            if let hr = snap.heartRate { snapshot["heart_rate"] = Int(hr) }
        } else {
            snapshot["last_metrics_age_s"] = "aucune métrique reçue"
        }
        if let planTitle { snapshot["program"] = planTitle }
        if let label = timerLabel, let end = timerEndsAt { snapshot["timer"] = "\(label) · reste \(Int(max(0, end.timeIntervalSinceNow))) s" }
        return ["session": snapshot, "lines": lines, "errors": errors]
    }

    static func compactArguments(_ json: [String: Any]) -> String {
        json.keys.sorted().map { key in
            let v = json[key]
            let text = (v as? String) ?? (v as? NSNumber).map { "\($0)" } ?? "…"
            return "\(key)=\(text.count > 60 ? String(text.prefix(57)) + "…" : text)"
        }.joined(separator: " ")
    }

    private func log(_ role: TranscriptLine.Role, _ text: String) {
        transcript.append(TranscriptLine(role: role, text: text))
        if transcript.count > 300 { transcript.removeFirst(transcript.count - 300) }
        saveCheckpoint()
    }
}
