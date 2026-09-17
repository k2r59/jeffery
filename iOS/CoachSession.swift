import Foundation
import Combine
import UIKit
import CoreLocation

struct TranscriptLine: Identifiable, Equatable {
    enum Role { case user, coach, info }
    let id = UUID()
    let role: Role
    var text: String
    let at = Date()
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
        didSet { if coachSpeaking != oldValue { audio.setDucking(coachSpeaking); sendMirror(force: true) } }
    }
    @Published private(set) var userSpeaking = false
    @Published private(set) var currentZone: HeartRateZone?
    @Published private(set) var pace: String?
    @Published private(set) var reference: ReferenceStatus?
    @Published var endedSummary: SessionSummary?
    @Published private(set) var goal: SessionGoal = .free
    @Published var proposal: GoalProposal?
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
    private var referenceTracker: ReferenceTracker?
    private var referenceName: String?
    private var lastClimbWarnAt: Date = .distantPast
    private var lastGhostWarnAt: Date = .distantPast
    private var cancellables = Set<AnyCancellable>()
    private var mirrorTimer: Timer?
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
    private let realtime = RealtimeClient()

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

    var latest: MetricsSnapshot? { connectivity.latest }

    init() {
        Prefs.registerDefaults()
        connectivity.activate()
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
        activity.onEvent = { [weak self] event in self?.handle(activityEvent: event) }
    }

    /// Marche, course, arrêt, montée, descente : Jeffrey réagit, avec au plus une réaction toutes les 30 s.
    private func handle(activityEvent event: ActivityMonitor.Event) {
        guard phase == .live, config.autoCues else { return }
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
            case (.walking, .running): reason = "il vient de repasser à la course : encourage la reprise"
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

    func start(kind: WorkoutKind, mode: CaptureMode, goal: SessionGoal = .free) {
        guard phase == .idle else { return }
        config = CoachConfig.load()
        self.goal = goal
        goalReached = false
        halfwayAnnounced = false
        proposal = nil
        lastCoachLine = nil
        guard !config.apiKey.isEmpty else {
            errorMessage = "Renseigne ta clé API OpenAI dans les réglages."
            return
        }
        self.kind = kind
        self.mode = mode
        errorMessage = nil
        transcript.removeAll()
        distanceHistory.removeAll()
        lastInjectedSnapshot = nil
        lastAnnouncedZone = nil
        currentZone = nil
        pace = nil
        reconnectAttempts = 0
        phase = .connecting
        status = "Connexion au coach…"
        sessionStartedAt = Date()
        lastMirror = nil
        hrSamples.removeAll()
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
        useAppleVoice = config.voiceEngine == "apple"
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

        realtime.connect(apiKey: config.apiKey, model: config.model, sessionConfig: sessionConfig())
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.phase == .connecting else { return }
            self.errorMessage = self.errorMessage ?? "Connexion au coach impossible (délai dépassé)."
            self.stop()
        }

        // Côté montre : lancement de la séance pilotée, ou demande de suivi de l'app Exercice.
        switch mode {
        case .owned:
            connectivity.launchWatchWorkout(kind: kind) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.log(.info, "Lancement montre : \(error.localizedDescription). Démarre la séance depuis la montre.")
                } else {
                    self.log(.info, "Séance lancée sur la montre.")
                }
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

    /// Télécommande montre : la montre ne décide de rien, elle demande à l'iPhone.
    private func handle(watchRequest payload: WatchCommandPayload) {
        switch payload.command {
        case .requestStart:
            guard phase == .idle else { return }
            let mode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: Prefs.mode) ?? "") ?? .companion
            UserDefaults.standard.set(payload.kind.rawValue, forKey: Prefs.kind)
            start(kind: payload.kind, mode: mode, goal: .free)
        case .requestPause, .requestResume:
            togglePause()
        case .requestEnd:
            stop()
        default:
            break
        }
        sendMirror(force: true)
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
                           distance: displayDistance, paused: isPaused, timerLabel: timerLabel, timerEndsAt: timerEndsAt)
    }

    private func sendMirror(force: Bool = false) {
        let m = mirrorSnapshot()
        if !force, let last = lastMirror, last.phase == m.phase, last.coachSpeaking == m.coachSpeaking, last.userSpeaking == m.userSpeaking,
           last.lastLine == m.lastLine, last.paused == m.paused, abs(last.elapsed - m.elapsed) < 4, last.goalReached == m.goalReached,
           last.timerLabel == m.timerLabel { return }
        lastMirror = m
        connectivity.sendCoachState(m)
    }

    func stop() {
        guard phase == .connecting || phase == .live else { return }
        phase = .ending
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

    var isPaused: Bool { latest?.state == .paused }

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
        connectivity.send(command: command, kind: kind, mode: mode)
        realtime.injectText(command == .pause ? "L'utilisateur met la séance en pause." : "L'utilisateur reprend la séance.")
    }

    /// Applique ou refuse la proposition d'objectif de Jeffrey.
    func resolveProposal(accept: Bool) {
        guard let p = proposal else { return }
        proposal = nil
        if accept {
            goal = p.goal
            goalReached = false
            halfwayAnnounced = false
            log(.info, "Nouvel objectif : \(p.goal.label)")
        }
        realtime.sendFunctionOutput(callId: p.callId, output: ["accepted": accept, "current_goal": goal.coachLabel()])
    }

    private func finishTeardown() {
        endTimeoutTask?.cancel()
        endTimeoutTask = nil
        realtime.disconnect()
        appleVoice.stop()
        audio.stop()
        audio.onCapturedPCM16 = { [weak self] data in self?.realtime.appendAudio(data) }
        UIApplication.shared.isIdleTimerDisabled = false
        responseInProgress = false
        coachSpeaking = false
        userSpeaking = false
        phase = .idle
        status = "Séance terminée"
        waitingForForeground = false
        sendMirror(force: true)
        if let start = sessionStartedAt {
            let elapsed = latest.map { $0.state == .running ? $0.elapsed + Date().timeIntervalSince($0.timestamp) : $0.elapsed } ?? Date().timeIntervalSince(start)
            endedSummary = SessionSummary(
                id: ISO8601DateFormatter().string(from: start), date: start, kind: kind,
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
            sessionStartedAt = nil
        }
    }

    // MARK: - Realtime

    private func sessionConfig() -> [String: Any] {
        [
            "type": "realtime",
            "instructions": config.instructions(kind: kind, mode: mode),
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
                "name": "cancel_timer",
                "description": "Arrêter le chronomètre en cours.",
                "parameters": ["type": "object", "properties": [:]],
            ], [
                "type": "function",
                "name": "get_time",
                "description": "Lire l'heure exacte de la séance : temps écoulé, temps ou distance restants sur l'objectif, chronomètre en cours.",
                "parameters": ["type": "object", "properties": [:]],
            ], [
                "type": "function",
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
                "name": "propose_goal",
                "description": "Proposer à l'utilisateur de modifier l'objectif de la séance en cours (raccourcir, allonger, changer de type). L'utilisateur devra confirmer sur son téléphone : ne considère pas le changement acquis avant la réponse.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": ["duration", "distance", "free"]],
                        "target": ["type": "number", "description": "Minutes si kind=duration, kilomètres si kind=distance, 0 si free"],
                        "reason": ["type": "string", "description": "Pourquoi, en une phrase courte"],
                    ],
                    "required": ["kind", "target", "reason"],
                ],
            ]],
            "tool_choice": "auto",
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "turn_detection": [
                        "type": "server_vad",
                        "threshold": NSDecimalNumber(string: config.micSensitivity.vadThreshold),
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": config.micSensitivity.silenceMs,
                        "create_response": true,
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
            Task { @MainActor in self?.log(.user, text) }
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
            Task { @MainActor in self?.responseInProgress = true }
        }
        realtime.callbacks.onResponseDone = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.responseInProgress = false
                if self.capturingAck {
                    self.capturingAck = false
                    if self.ackCaptureBuffer.count > 4_800 {
                        self.ackAudio = self.ackCaptureBuffer
                        try? self.ackCaptureBuffer.write(to: self.ackFileURL, options: .atomic)
                    }
                    self.ackCaptureBuffer = Data()
                    if self.pendingGreeting { self.pendingGreeting = false; self.sendGreeting() }
                    return
                }
                if self.useAppleVoice {
                    if self.phase == .ending, !self.appleVoice.isSpeaking { self.finishTeardown() }
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
        if name == "get_time" {
            realtime.sendFunctionOutput(callId: callId, output: timeStatus())
            return
        }
        if name == "cancel_timer" {
            cancelTimer()
            realtime.sendFunctionOutput(callId: callId, output: ["cancelled": true])
            return
        }
        if name == "start_timer" {
            let seconds = max(5, (json["seconds"] as? Int) ?? Int((json["seconds"] as? Double) ?? 30))
            let label = (json["label"] as? String ?? "bloc").trimmingCharacters(in: .whitespaces)
            let rest = max(0, (json["rest_seconds"] as? Int) ?? 0)
            let repeats = max(1, (json["repeats"] as? Int) ?? 1)
            startTimer(seconds: seconds, label: label, rest: rest, repeats: repeats)
            var out = timeStatus()
            out["started"] = true
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
        guard name == "propose_goal",
              let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kindRaw = json["kind"] as? String, let kind = SessionGoal.Kind(rawValue: kindRaw) else {
            realtime.sendFunctionOutput(callId: callId, output: ["error": "arguments invalides"])
            return
        }
        let value = (json["target"] as? Double) ?? 0
        let target: Double = kind == .duration ? value * 60 : (kind == .distance ? value * 1000 : 0)
        let reason = json["reason"] as? String ?? ""
        proposal = GoalProposal(callId: callId, goal: SessionGoal(kind: kind, target: target), reason: reason)
        log(.info, "Jeffrey propose : \(proposal!.goal.label)\(reason.isEmpty ? "" : " · \(reason)")")
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
        return out
    }

    func startTimer(seconds: Int, label: String, rest: Int = 0, repeats: Int = 1) {
        cancelTimer()
        timerWorkSeconds = seconds
        timerRestSeconds = rest
        timerRepeatsLeft = repeats
        timerPhaseIsWork = true
        runTimerPhase(seconds: seconds, label: repeats > 1 ? "\(label) 1/\(repeats)" : label, baseLabel: label, index: 1)
    }

    private func runTimerPhase(seconds: Int, label: String, baseLabel: String, index: Int) {
        timerLabel = label
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
        sendMirror(force: true)
        realtime.injectText("[CHRONO terminé] « \(finished) ». " + metricsLine(prefix: "[MÉTRIQUES]"))
        realtime.requestResponse(instructions: "Le chrono « \(finished) » vient de sonner : annonce-le et donne la consigne suivante en une ou deux phrases.")
    }

    func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        timerLabel = nil
        timerEndsAt = nil
        timerRepeatsLeft = 0
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
        errorMessage = nil
        reconnectAttempts = 0
        if phase == .connecting {
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
                stop()
                return
            }
            phase = .live
            status = "Coach en ligne"
            log(.info, "Coach connecté (\(config.model), voix \(config.voice)).")
            startTimers()
            sendMirror(force: true)
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
            realtime.injectText("Reconnexion après une coupure réseau ; la séance continue. " + metricsLine(prefix: "[MÉTRIQUES]"))
        }
    }

    private func sendGreeting() {
        let name = config.userName.isEmpty ? "" : " Appelle-le \(config.userName)."
        realtime.requestResponse(instructions: "Présente-toi comme Jeffrey en une phrase chaleureuse.\(name) Rappelle l'objectif s'il y en a un (sinon demande-le en une question courte), et lance la séance.")
    }

    /// Si aucune parole de Jeffrey n'arrive dans la seconde qui suit la fin de la tienne, on joue « Je regarde. ».
    private func scheduleAckIfSlow() {
        let stoppedAt = Date()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard let self, self.phase == .live else { return }
            guard self.lastAudioDeltaAt < stoppedAt, Date().timeIntervalSince(self.lastAckAt) > 8 else { return }
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
        guard phase == .live || phase == .connecting else { return }
        // Clé refusée ou accès interdit : inutile de retenter.
        if let err = errorMessage?.lowercased(), err.contains("api key") || err.contains("invalid_api_key") || err.contains("unauthorized") {
            errorMessage = "Clé API refusée par OpenAI : vérifie-la dans les réglages (elle commence par sk-)."
            stop()
            return
        }
        reconnectAttempts += 1
        guard reconnectAttempts <= 5 else {
            errorMessage = "Connexion perdue : \(reason)"
            stop()
            return
        }
        status = "Reconnexion (\(reconnectAttempts)/5)…"
        let delay = Double(reconnectAttempts) * 1.5
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.phase == .live || self.phase == .connecting else { return }
            self.realtime.connect(apiKey: self.config.apiKey, model: self.config.model, sessionConfig: self.sessionConfig())
        }
    }

    private func scheduleSpeakingReset() {
        Task { [weak self] in
            // On attend la fin de la lecture des tampons avant de passer coachSpeaking à false.
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                if !self.audio.isPlaying {
                    await MainActor.run { self.coachSpeaking = false }
                    return
                }
            }
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
        if let d = snap.distance {
            distanceHistory.append((snap.timestamp, d))
            distanceHistory.removeAll { snap.timestamp.timeIntervalSince($0.0) > 45 }
        }
        pace = computePace(snap)
        if let hr = snap.heartRate, snap.state == .running { hrSamples.append(hr) }
        if let hr = snap.heartRate {
            let zone = HeartRateZone.zone(for: hr, maxHR: config.maxHR)
            currentZone = zone
            if phase == .live, config.autoCues, let previous = lastAnnouncedZone, previous != zone,
               Date().timeIntervalSince(lastCueAt) > 45, zone.rawValue >= 5 || (previous.rawValue >= 5 && zone.rawValue <= 3) {
                cue(reason: zone.rawValue >= 5 ? "FC en zone 5 (\(Int(hr)) bpm) : vérifier que c'est voulu, sinon lever le pied" : "FC redescendue de la zone 5 : bien récupéré")
            }
            if lastAnnouncedZone == nil { lastAnnouncedZone = zone }
        }
        evaluateGoal()
        if phase == .live, snap.state == .ended {
            log(.info, mode == .owned ? "La montre a terminé la séance." : "La séance de l'app Exercice est terminée.")
            stop()
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
            parts.append("objectif \(goal.coachLabel()) : \(Int(p.fraction * 100)) %\(p.remaining.map { ", \($0)" } ?? "")\(goalReached ? " · ATTEINT" : "")")
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
        if s.state == .paused { parts.append("séance EN PAUSE") }
        if s.state == .ended { parts.append("séance terminée côté montre") }
        let age = Int(Date().timeIntervalSince(s.lastSampleAt ?? s.timestamp))
        parts.append("dernière mesure il y a \(age) s")
        return "\(prefix) " + parts.joined(separator: " · ")
    }

    private func startTimers() {
        stopTimers()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: min(config.metricsInterval, 15), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.injectMetricsIfChanged() }
        }
        goalTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateGoal(); self?.detectStruggle() }
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
        lastInjectedSnapshot = latest
        realtime.injectText(metricsLine(prefix: "[MÉTRIQUES]"))
    }

    /// Coaching de fond : Jeffrey reste présent, avec un contenu qui a une raison d'être (kilomètre, allure, technique, objectif).
    private func routineCheck() {
        guard phase == .live else { return }
        let now = Date()
        let silence = now.timeIntervalSince(max(lastCoachSpokeAt, lastCueAt))
        guard silence >= 30 else { return }

        // 1) Passage kilométrique : temps du dernier km, un vrai repère de coach.
        if let d = displayDistance, kind.usesDistance {
            let km = Int(d / 1000)
            if km > lastKmAnnounced {
                let split = lastKmAt.map { now.timeIntervalSince($0.at) }
                lastKmAnnounced = km
                lastKmAt = (km, now)
                let splitText = split.map { " en \(Formatters.elapsed($0))" } ?? ""
                cue(reason: "kilomètre \(km) passé\(splitText) : annonce-le, situe l'allure par rapport à l'objectif ou au ressenti, un mot d'encouragement")
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
        guard phase == .live, config.autoCues else { return }
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
            let cadenceDrop = (activity.cadence ?? 999) < 145 && activity.activity == .running
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
            cue(reason: "objectif atteint : \(goal.coachLabel()). Félicite et propose la suite (continuer tranquille ou terminer)")
        } else if !halfwayAnnounced, p.fraction >= 0.5, config.goalCues {
            halfwayAnnounced = true
            cue(reason: "mi-parcours de l'objectif (\(goal.coachLabel()))")
        }
    }

    /// Interventions prioritaires : elles passent devant l'espacement (chrono, objectif atteint, galère, arrêt long).
    private func isPriority(_ reason: String) -> Bool {
        ["objectif atteint", "galère", "chrono", "arrêt depuis", "demande manuelle", "zone 5"].contains { reason.lowercased().contains($0) }
    }

    /// Demande une intervention courte du coach, sauf si quelqu'un parle déjà ou si c'est trop tôt.
    func cue(reason: String) {
        guard phase == .live, realtime.isConnected, !responseInProgress, !userSpeaking, !coachSpeaking else { return }
        let now = Date()
        if !isPriority(reason) {
            // Conversation en cours avec l'utilisateur : on ne l'interrompt pas avec du spontané.
            guard now.timeIntervalSince(lastUserSpokeAt) >= 60 else { return }
            // Silence minimal après la dernière phrase de Jeffrey.
            guard now.timeIntervalSince(lastCoachSpokeAt) >= 30 else { return }
            // Espacement entre deux interventions spontanées.
            let spacing: TimeInterval = config.presence == "discreet" ? 180 : 90
            guard now.timeIntervalSince(lastSpontaneousCueAt) >= spacing else { return }
            lastSpontaneousCueAt = now
        } else {
            guard now.timeIntervalSince(lastCoachSpokeAt) >= 8 else { return }
        }
        lastCueAt = now
        if let hr = latest?.heartRate {
            lastAnnouncedZone = HeartRateZone.zone(for: hr, maxHR: config.maxHR)
            lastCueZone = lastAnnouncedZone
        }
        lastInjectedSnapshot = latest
        realtime.injectText(metricsLine(prefix: "[MÉTRIQUES]") + " · motif : \(reason)")
        realtime.requestResponse(instructions: "Intervention coach spontanée (\(reason)) : 1 à 2 phrases orales, utiles, sans répéter la précédente.")
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

    private func log(_ role: TranscriptLine.Role, _ text: String) {
        transcript.append(TranscriptLine(role: role, text: text))
        if transcript.count > 300 { transcript.removeFirst(transcript.count - 300) }
    }
}
