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
        didSet { if coachSpeaking != oldValue { audio.setDucking(coachSpeaking) } }
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
    private var sessionStartedAt: Date?
    private var hrSamples: [Double] = []
    private var referenceTracker: ReferenceTracker?
    private var referenceName: String?
    private var lastClimbWarnAt: Date = .distantPast
    private var lastGhostWarnAt: Date = .distantPast
    private var cancellables = Set<AnyCancellable>()

    let connectivity = PhoneConnectivity()
    let gps = RouteRecorder()
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
        connectivity.requestHealthAuthorization()
        connectivity.onSnapshot = { [weak self] snap in self?.handle(snapshot: snap) }
        wireRealtime()
        audio.onCapturedPCM16 = { [weak self] data in self?.realtime.appendAudio(data) }
        audio.onRouteChanged = { [weak self] name in
            Task { @MainActor in self?.status = "Audio : \(name)" }
        }
        gps.$lastLocation
            .compactMap { $0 }
            .sink { [weak self] location in self?.handle(location: location) }
            .store(in: &cancellables)
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
        hrSamples.removeAll()
        UIApplication.shared.isIdleTimerDisabled = true
        audio.duckOthersWhileSpeaking = UserDefaults.standard.object(forKey: Prefs.duckMusic) as? Bool ?? true
        audio.noiseGate = config.micSensitivity.noiseGate
        gps.start(kind: kind)
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
                if let error {
                    self.log(.info, "Montre : \(error.localizedDescription). Sur la montre, ouvre WatchCoach et touche « Suivre l'app Exercice ».")
                } else {
                    self.log(.info, "La montre suit l'app Exercice. Lance ta séance dans l'app Exercice si ce n'est pas fait.")
                }
            }
        }
    }

    func stop() {
        guard phase == .connecting || phase == .live else { return }
        phase = .ending
        status = "Fin de séance…"
        stopTimers()
        gps.stop()
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
        if let s = latest {
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
        audio.stop()
        audio.onCapturedPCM16 = { [weak self] data in self?.realtime.appendAudio(data) }
        UIApplication.shared.isIdleTimerDisabled = false
        responseInProgress = false
        coachSpeaking = false
        userSpeaking = false
        phase = .idle
        status = "Séance terminée"
        if let start = sessionStartedAt {
            let elapsed = latest.map { $0.state == .running ? $0.elapsed + Date().timeIntervalSince($0.timestamp) : $0.elapsed } ?? Date().timeIntervalSince(start)
            endedSummary = SessionSummary(
                id: ISO8601DateFormatter().string(from: start), date: start, kind: kind,
                elapsed: elapsed,
                distance: displayDistance,
                averageHeartRate: hrSamples.isEmpty ? nil : hrSamples.reduce(0, +) / Double(hrSamples.count),
                maxHeartRate: hrSamples.max(), feeling: nil,
                goalLabel: goal.kind == .free ? nil : goal.label, goalReached: goal.kind == .free ? nil : goalReached,
                lastCoachLine: transcript.last(where: { $0.role == .coach })?.text)
            sessionStartedAt = nil
        }
    }

    // MARK: - Realtime

    private func sessionConfig() -> [String: Any] {
        [
            "type": "realtime",
            "instructions": config.instructions(kind: kind, mode: mode),
            "output_modalities": ["audio"],
            "tools": [[
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
            self.audio.enqueuePlayback(pcm16: data)
            Task { @MainActor in if !self.coachSpeaking { self.coachSpeaking = true } }
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
            Task { @MainActor in self?.userSpeaking = false }
        }
        realtime.callbacks.onResponseStarted = { [weak self] in
            Task { @MainActor in self?.responseInProgress = true }
        }
        realtime.callbacks.onResponseDone = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.responseInProgress = false
                self.scheduleSpeakingReset()
                if self.phase == .ending { self.scheduleTeardownAfterPlayback() }
            }
        }
        realtime.callbacks.onFunctionCall = { [weak self] name, callId, arguments in
            Task { @MainActor in self?.handleFunctionCall(name: name, callId: callId, arguments: arguments) }
        }
        realtime.callbacks.onError = { [weak self] message in
            Task { @MainActor in
                self?.errorMessage = message
                self?.log(.info, "Erreur : \(message)")
            }
        }
        realtime.callbacks.onDisconnected = { [weak self] reason in
            Task { @MainActor in self?.handleDisconnect(reason) }
        }
    }

    private func handleFunctionCall(name: String, callId: String, arguments: String) {
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

    private func onRealtimeReady() {
        errorMessage = nil
        reconnectAttempts = 0
        if phase == .connecting {
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
            realtime.injectText("La séance de \(kind.coachLabel) démarre maintenant. Objectif du jour : \(goal.coachLabel()). " + metricsLine(prefix: "[MÉTRIQUES]"))
            let name = config.userName.isEmpty ? "" : " Appelle-le \(config.userName)."
            realtime.requestResponse(instructions: "Présente-toi comme Jeffrey en une phrase chaleureuse.\(name) Rappelle l'objectif s'il y en a un (sinon demande-le en une question courte), et lance la séance.")
        } else if phase == .live {
            status = "Coach reconnecté"
            realtime.injectText("Reconnexion après une coupure réseau ; la séance continue. " + metricsLine(prefix: "[MÉTRIQUES]"))
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
               Date().timeIntervalSince(lastCueAt) > 25, abs(zone.rawValue - previous.rawValue) >= 1 {
                cue(reason: "changement de zone cardiaque : \(previous.label) → \(zone.label)")
            }
            if lastAnnouncedZone == nil { lastAnnouncedZone = zone }
        }
        evaluateGoal()
        if phase == .live, snap.state == .ended, mode == .owned {
            log(.info, "La montre a terminé la séance.")
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
            Task { @MainActor in self?.evaluateGoal() }
        }
        if config.autoCues {
            cueTimer = Timer.scheduledTimer(withTimeInterval: config.cueInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.cue(reason: "point régulier") }
            }
        }
        lastCueAt = Date()
    }

    private func stopTimers() {
        metricsTimer?.invalidate()
        cueTimer?.invalidate()
        goalTimer?.invalidate()
        metricsTimer = nil
        cueTimer = nil
        goalTimer = nil
    }

    /// Le temps avance même si la montre se tait : on injecte à intervalle fixe, données nouvelles ou non.
    private func injectMetricsIfChanged() {
        guard phase == .live, realtime.isConnected else { return }
        lastInjectedSnapshot = latest
        realtime.injectText(metricsLine(prefix: "[MÉTRIQUES]"))
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

    /// Demande une intervention courte du coach, sauf si quelqu'un parle déjà.
    func cue(reason: String) {
        guard phase == .live, realtime.isConnected, !responseInProgress, !userSpeaking, !coachSpeaking else { return }
        lastCueAt = Date()
        if let hr = latest?.heartRate { lastAnnouncedZone = HeartRateZone.zone(for: hr, maxHR: config.maxHR) }
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
    }

    private func log(_ role: TranscriptLine.Role, _ text: String) {
        transcript.append(TranscriptLine(role: role, text: text))
        if transcript.count > 300 { transcript.removeFirst(transcript.count - 300) }
    }
}
