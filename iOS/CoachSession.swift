import Foundation
import Combine
import UIKit

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
    @Published private(set) var coachSpeaking = false
    @Published private(set) var userSpeaking = false
    @Published private(set) var currentZone: HeartRateZone?
    @Published private(set) var pace: String?

    let connectivity = PhoneConnectivity()
    private let audio = AudioPipeline()
    private let realtime = RealtimeClient()

    private var config = CoachConfig.load()
    private var kind: WorkoutKind = .running
    private var mode: CaptureMode = .companion
    private var responseInProgress = false
    private var partialCoachLine: TranscriptLine?
    private var metricsTimer: Timer?
    private var cueTimer: Timer?
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
    }

    // MARK: - Démarrage / arrêt

    func start(kind: WorkoutKind, mode: CaptureMode) {
        guard phase == .idle else { return }
        config = CoachConfig.load()
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
        UIApplication.shared.isIdleTimerDisabled = true

        realtime.connect(apiKey: config.apiKey, model: config.model, sessionConfig: sessionConfig())

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
    }

    // MARK: - Realtime

    private func sessionConfig() -> [String: Any] {
        [
            "type": "realtime",
            "instructions": config.instructions(kind: kind, mode: mode),
            "output_modalities": ["audio"],
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "turn_detection": [
                        "type": "server_vad",
                        "threshold": 0.6,
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": 700,
                        "create_response": true,
                        "interrupt_response": true,
                    ],
                    "transcription": ["model": "gpt-4o-mini-transcribe", "language": "fr"],
                ],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "voice": config.voice,
                    "speed": 1.05,
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
            guard let self else { return }
            self.audio.stopPlayback()
            Task { @MainActor in
                self.userSpeaking = true
                self.coachSpeaking = false
            }
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
            realtime.injectText("La séance de \(kind.coachLabel) démarre maintenant. " + metricsLine(prefix: "[MÉTRIQUES]"))
            realtime.requestResponse(instructions: "Salue l'utilisateur en une phrase, rappelle l'objectif s'il y en a un (sinon demande-le en une question courte), et lance la séance.")
        } else if phase == .live {
            status = "Coach reconnecté"
            realtime.injectText("Reconnexion après une coupure réseau ; la séance continue. " + metricsLine(prefix: "[MÉTRIQUES]"))
        }
    }

    private func handleDisconnect(_ reason: String) {
        guard phase == .live || phase == .connecting else { return }
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
        if let hr = snap.heartRate {
            let zone = HeartRateZone.zone(for: hr, maxHR: config.maxHR)
            currentZone = zone
            if phase == .live, config.autoCues, let previous = lastAnnouncedZone, previous != zone,
               Date().timeIntervalSince(lastCueAt) > 25, abs(zone.rawValue - previous.rawValue) >= 1 {
                cue(reason: "changement de zone cardiaque : \(previous.label) → \(zone.label)")
            }
            if lastAnnouncedZone == nil { lastAnnouncedZone = zone }
        }
        if phase == .live, snap.state == .ended, mode == .owned {
            log(.info, "La montre a terminé la séance.")
        }
    }

    private func computePace(_ snap: MetricsSnapshot) -> String? {
        if let v = snap.speed, let p = Formatters.pace(speedMetersPerSecond: v) { return p }
        guard let first = distanceHistory.first, let last = distanceHistory.last, last.0 > first.0 else { return nil }
        let dt = last.0.timeIntervalSince(first.0)
        let dd = last.1 - first.1
        guard dt >= 10, dd > 5 else { return nil }
        return Formatters.pace(speedMetersPerSecond: dd / dt)
    }

    private func metricsLine(prefix: String) -> String {
        guard let s = latest else { return "\(prefix) aucune donnée reçue de la montre pour l'instant." }
        var parts: [String] = ["temps \(Formatters.elapsed(s.elapsed))"]
        if let hr = s.heartRate {
            let zone = HeartRateZone.zone(for: hr, maxHR: config.maxHR)
            let pct = Int(hr / config.maxHR * 100)
            parts.append("FC \(Int(hr)) bpm (\(zone.label) \(zone.description), \(pct) % FCmax)")
        } else {
            parts.append("FC inconnue")
        }
        if s.kind.usesDistance {
            if let d = s.distance { parts.append("distance \(Formatters.distance(d))") }
            if let p = pace { parts.append("allure \(p)") }
        }
        if let e = s.activeEnergy { parts.append("\(Int(e)) kcal") }
        if s.state == .paused { parts.append("séance EN PAUSE") }
        if s.state == .ended { parts.append("séance terminée côté montre") }
        let age = Int(Date().timeIntervalSince(s.lastSampleAt ?? s.timestamp))
        parts.append("dernière mesure il y a \(age) s")
        return "\(prefix) " + parts.joined(separator: " · ")
    }

    private func startTimers() {
        stopTimers()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: config.metricsInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.injectMetricsIfChanged() }
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
        metricsTimer = nil
        cueTimer = nil
    }

    private func injectMetricsIfChanged() {
        guard phase == .live, realtime.isConnected, let snap = latest, snap != lastInjectedSnapshot else { return }
        lastInjectedSnapshot = snap
        realtime.injectText(metricsLine(prefix: "[MÉTRIQUES]"))
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
        partialCoachLine = nil
    }

    private func log(_ role: TranscriptLine.Role, _ text: String) {
        transcript.append(TranscriptLine(role: role, text: text))
        if transcript.count > 300 { transcript.removeFirst(transcript.count - 300) }
    }
}
