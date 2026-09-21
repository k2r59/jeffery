import Foundation
import Combine

#if DEBUG
/// Montre simulée (simulateur iOS) : FC qui monte puis descend, distance qui avance, pause/fin honorées.
/// Activée par WATCHCOACH_FAKE_WATCH=1.
@MainActor
final class FakeWatch {
    static let enabled = ProcessInfo.processInfo.environment["WATCHCOACH_FAKE_WATCH"] == "1"
    private var timer: Timer?
    private var start = Date()
    private var paused = false
    private var pausedTotal: TimeInterval = 0
    private var pauseStart: Date?
    private var distance: Double = 0
    private var energy: Double = 0
    private weak var connectivity: PhoneConnectivity?
    private var kind: WorkoutKind = .running

    nonisolated init(connectivity: PhoneConnectivity) { self.connectivity = connectivity }

    func handle(command: WatchCommand, kind: WorkoutKind) {
        switch command {
        case .start:
            self.kind = kind; start = Date(); paused = false; pausedTotal = 0; distance = 0; energy = 0
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            tick()
        case .pause: if !paused { paused = true; pauseStart = Date() }; tick()
        case .resume: if paused, let p = pauseStart { pausedTotal += Date().timeIntervalSince(p) }; paused = false; pauseStart = nil; tick()
        case .end:
            timer?.invalidate(); timer = nil
            var s = snapshot(); s.state = .ended
            connectivity?.debugInject(s)
        default: break
        }
    }

    private func elapsed() -> TimeInterval {
        var e = Date().timeIntervalSince(start) - pausedTotal
        if let p = pauseStart { e -= Date().timeIntervalSince(p) }
        return max(0, e)
    }

    private func snapshot() -> MetricsSnapshot {
        let e = elapsed()
        // Profil : échauffement 0-60 s (110→140), effort 60-150 s (150→172, zone 5 vers 120 s), récup ensuite.
        let hr: Double = e < 60 ? 110 + e * 0.5 : (e < 150 ? 150 + (e - 60) * 0.25 : max(120, 172 - (e - 150) * 0.6))
        var s = MetricsSnapshot.idle(kind: kind, mode: .owned) // la montre factice « décide » : pas de séance native, elle pilote
        s.state = paused ? .paused : .running
        s.elapsed = e
        s.heartRate = hr
        s.distance = distance
        s.activeEnergy = energy
        s.speed = paused ? 0 : 2.8
        s.lastSampleAt = Date()
        s.sessionStart = start
        return s
    }

    private func tick() {
        if !paused { distance += 2.8 * 2; energy += 0.4 }
        connectivity?.debugInject(snapshot())
    }
}

/// Serveur Realtime simulé : joue les événements serveur attendus (session, réponses texte + audio silencieux,
/// transcriptions, appels de fonction déclenchés par mots-clés). Activé par WATCHCOACH_FAKE_REALTIME=1.
final class FakeRealtimeBackend {
    static let enabled = ProcessInfo.processInfo.environment["WATCHCOACH_FAKE_REALTIME"] == "1"
    var deliver: (([String: Any]) -> Void)?
    private var responseCounter = 0
    private var lastConsigne = ""
    private var pendingTimerCall = false
    private var workoutsAsked = false
    private var pendingWorkoutId: String?
    private let queue = DispatchQueue(label: "fake.realtime")

    func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "session.update":
            emit(["type": "session.updated"], after: 0.1)
        case "conversation.item.create":
            if let item = event["item"] as? [String: Any], let content = item["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String, text.hasPrefix("[CONSIGNE]") { lastConsigne = text }
            // Sortie de suggest_workouts : on retient la première séance pour la lancer à la réponse suivante.
            if let item = event["item"] as? [String: Any], item["type"] as? String == "function_call_output",
               let out = item["output"] as? String, let data = out.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["workouts"] as? [[String: Any]], let id = list.first?["id"] as? String {
                pendingWorkoutId = id
            }
        case "response.create":
            respond()
        case "input_audio_buffer.append":
            break
        default: break
        }
    }

    private func respond() {
        responseCounter += 1
        let n = responseCounter
        let consigne = lastConsigne.lowercased()
        emit(["type": "response.created", "response": ["id": "resp_\(n)"]], after: 0.2)
        // Simulation d'un appel de fonction : la consigne de salut déclenche start_timer une fois (bloc 20 s).
        if consigne.contains("présente-toi") || consigne.contains("tu veux quoi"), !pendingTimerCall {
            pendingTimerCall = true
            let args = "{\"seconds\": 20, \"label\": \"test\"}"
            emit(["type": "response.function_call_arguments.done", "name": "start_timer", "call_id": "call_\(n)", "arguments": args], after: 0.6)
            emit(["type": "response.done", "response": ["id": "resp_\(n)", "status": "completed"]], after: 0.9)
            return
        }
        // Après le premier chrono : « demande d'exercices » simulée → suggest_workouts, puis start_workout.
        if consigne.contains("chrono"), !workoutsAsked {
            workoutsAsked = true
            emit(["type": "response.function_call_arguments.done", "name": "suggest_workouts", "call_id": "call_\(n)", "arguments": "{\"level\": \"beginner\"}"], after: 0.6)
            emit(["type": "response.done", "response": ["id": "resp_\(n)", "status": "completed"]], after: 0.9)
            return
        }
        if let id = pendingWorkoutId {
            pendingWorkoutId = nil
            emit(["type": "response.function_call_arguments.done", "name": "start_workout", "call_id": "call_\(n)", "arguments": "{\"id\": \"\(id)\"}"], after: 0.6)
            emit(["type": "response.done", "response": ["id": "resp_\(n)", "status": "completed"]], after: 0.9)
            return
        }
        let text: String = consigne.contains("débrief") ? "Bien joué, belle séance, on se revoit bientôt."
            : consigne.contains("programme") || consigne.contains("bloc suivant") ? "Bloc suivant, on y va."
            : consigne.contains("chrono") ? "Le chrono a sonné, on enchaîne tranquillement."
            : "Réponse simulée numéro \(n), tout va bien."
        var t = 1.0
        for word in text.split(separator: " ") {
            emit(["type": "response.output_audio_transcript.delta", "delta": String(word) + " "], after: t)
            emit(["type": "response.output_audio.delta", "delta": Data(count: 4800).base64EncodedString()], after: t)
            t += 0.12
        }
        emit(["type": "response.output_audio_transcript.done", "transcript": text], after: t)
        emit(["type": "response.done", "response": ["id": "resp_\(n)", "status": "completed"]], after: t + 0.2)
    }

    private func emit(_ event: [String: Any], after: TimeInterval) {
        queue.asyncAfter(deadline: .now() + after) { [weak self] in self?.deliver?(event) }
    }

    func start() {
        emit(["type": "session.created"], after: 0.3)
    }
}
#endif
