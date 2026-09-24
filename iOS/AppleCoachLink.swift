import Foundation
import AVFAudio
import Speech
import FoundationModels

/// Ce que la séance attend du cerveau de Jeffrey, quel qu'il soit : OpenAI Realtime (`RealtimeClient`) ou Apple AI
/// (`AppleCoachLink`, tout sur l'iPhone). Même vocabulaire d'événements des deux côtés.
protocol CoachLink: AnyObject {
    var callbacks: RealtimeClient.Callbacks { get set }
    var isConnected: Bool { get }
    func connect(apiKey: String, model: String, sessionConfig: [String: Any])
    func disconnect()
    func appendAudio(_ pcm16: Data)
    func injectText(_ text: String, role: String, itemId: String?)
    func injectMetrics(_ text: String)
    func requestResponse(instructions: String?)
    func sendFunctionOutput(callId: String, output: [String: Any], thenRespond: Bool)
    func cancelPendingResponses()
    /// Jeffrey parle sur le haut-parleur : le cerveau Apple coupe son écoute pour ne pas se transcrire lui-même.
    func setCoachSpeaking(_ speaking: Bool)
}

extension RealtimeClient: CoachLink {
    func setCoachSpeaking(_ speaking: Bool) {}
}

/// Raccourcis avec valeurs par défaut (un protocole n'en accepte pas), pour garder les appels de `CoachSession` tels quels.
extension CoachLink {
    func injectText(_ text: String) { injectText(text, role: "system", itemId: nil) }
    func requestResponse() { requestResponse(instructions: nil) }
    func sendFunctionOutput(callId: String, output: [String: Any]) { sendFunctionOutput(callId: callId, output: output, thenRespond: true) }
}

/// Apple AI : reconnaissance vocale iOS sur l'appareil, modèle Apple (Foundation Models) avec les outils de la séance,
/// texte rendu phrase par phrase à la voix Apple par `CoachSession` (mode `useAppleVoice`). Zéro réseau, zéro compte.
///
/// Limites assumées : modèle plus petit (fenêtre de 4 096 jetons, renouvelée avec un résumé quand elle déborde),
/// latence d'une à trois secondes, pas d'interruption au milieu d'une phrase.
final class AppleCoachLink: NSObject, CoachLink {
    var callbacks = RealtimeClient.Callbacks()
    private(set) var isConnected = false

    private enum Request { case user(String), cue(String?) }

    private var backend: AppleAnalyst.Backend = .onDevice
    private var instructions = ""
    private var session: LanguageModelSession?
    private var tools: [any Tool] = []
    /// Messages système en attente (métriques, événements) : joints au prochain prompt.
    private var pendingContext: [String] = []
    private var lastMetrics: String?
    private var queue: [Request] = []
    private var responding = false
    private var currentTask: Task<Void, Never>?
    /// Derniers échanges, pour repartir avec un résumé quand la fenêtre du modèle déborde.
    private var history: [(role: String, text: String)] = []
    private var toolCounter = 0
    private var toolWaiters: [String: CheckedContinuation<String, Never>] = [:]
    private let lock = NSLock()

    // Reconnaissance vocale
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private var partial = ""
    private var userSpeaking = false
    private var utteranceTimer: Timer?
    private var coachSpeaking = false
    private var restartTimer: Timer?

    // MARK: Connexion

    func connect(apiKey: String, model: String, sessionConfig: [String: Any]) {
        instructions = (sessionConfig["instructions"] as? String ?? "") + """


        Tu tournes sur l'iPhone (Apple AI). Réponds toujours en texte, en français, 1 à 3 phrases orales, sans liste ni \
        markdown. Les messages qui commencent par [MÉTRIQUES], [CHRONO], [PROGRAMME] ou [CONSIGNE] viennent de l'application, \
        pas du sportif. Utilise les outils quand la consigne le demande (chrono, objectif, montre, rappel, note, séances types).
        """
        guard let b = AppleAnalyst.availableBackend(preferLocal: true) else {
            callbacks.onError("Apple AI indisponible : " + AppleAnalyst.availabilityDescription())
            callbacks.onDisconnected("Apple Intelligence indisponible")
            return
        }
        backend = b
        // Administrateur : l'outil de journal figure dans la liste OpenAI ; on s'aligne dessus (rien d'autre à transmettre).
        let admin = ((sessionConfig["tools"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "get_session_log" }
        tools = makeTools(admin: admin)
        session = makeSession(recap: nil)
        session?.prewarm()
        isConnected = true
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.isConnected else { return }
                if status == .authorized { self.startRecognition() } else { self.callbacks.onError("Reconnaissance vocale refusée : Réglages › Jeffrey › Reconnaissance vocale.") }
                self.callbacks.onReady()
            }
        }
    }

    func disconnect() {
        isConnected = false
        currentTask?.cancel(); currentTask = nil
        queue.removeAll()
        stopRecognition()
        lock.lock(); let waiters = toolWaiters; toolWaiters.removeAll(); lock.unlock()
        waiters.values.forEach { $0.resume(returning: "{\"cancelled\":true}") }
        session = nil
        callbacks.onDisconnected("Apple AI arrêté")
    }

    private func makeSession(recap: String?) -> LanguageModelSession {
        var text = instructions
        if let recap { text += "\n\nDerniers échanges de cette séance (pour continuité) :\n" + recap }
        switch backend {
        case .privateCloud: return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: text)
        case .onDevice: return LanguageModelSession(model: SystemLanguageModel.default, tools: tools, instructions: text)
        }
    }

    // MARK: Contexte et réponses

    func injectText(_ text: String, role: String = "system", itemId: String? = nil) {
        DispatchQueue.main.async {
            // Texte au nom du sportif (bouton de la montre) : un tour utilisateur, pas du contexte.
            if role == "user" { self.queue.append(.user(text)); self.pump(); return }
            self.pendingContext.append(text)
            if self.pendingContext.count > 8 { self.pendingContext.removeFirst(self.pendingContext.count - 8) }
        }
    }

    func injectMetrics(_ text: String) {
        DispatchQueue.main.async { self.lastMetrics = text }
    }

    func requestResponse(instructions: String? = nil) {
        DispatchQueue.main.async {
            self.queue.append(.cue(instructions))
            self.pump()
        }
    }

    func cancelPendingResponses() {
        DispatchQueue.main.async { self.queue.removeAll() }
    }

    func sendFunctionOutput(callId: String, output: [String: Any], thenRespond: Bool = true) {
        let text = (try? JSONSerialization.data(withJSONObject: output)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        lock.lock(); let waiter = toolWaiters.removeValue(forKey: callId); lock.unlock()
        waiter?.resume(returning: text)
    }

    func setCoachSpeaking(_ speaking: Bool) {
        DispatchQueue.main.async {
            self.coachSpeaking = speaking
            // Sa propre voix ne doit pas devenir « ce que dit le sportif » : on repart d'une écoute vierge après sa phrase.
            if !speaking { self.partial = ""; self.restartRecognition() }
        }
    }

    private func pump() {
        guard isConnected, !responding, let next = queue.first, let session else { return }
        queue.removeFirst()
        responding = true
        var parts: [String] = []
        if let lastMetrics { parts.append(lastMetrics) }
        parts.append(contentsOf: pendingContext)
        pendingContext.removeAll()
        let context = parts.isEmpty ? "" : "Messages de l'application :\n" + parts.joined(separator: "\n") + "\n\n"
        let prompt: String
        switch next {
        case .user(let text):
            history.append(("Lui", text))
            prompt = context + "Le sportif te dit : « \(text) »\nRéponds-lui, à l'oral, en une à trois phrases."
        case .cue(let cue):
            prompt = context + "[CONSIGNE] " + (cue ?? "Réagis à ce qui vient de se passer, en une ou deux phrases.") + "\nRéponds à l'oral, en une à trois phrases."
        }
        callbacks.onResponseStarted()
        currentTask = Task { [weak self] in
            guard let self else { return }
            var text = ""
            do {
                text = try await self.generate(session: session, prompt: prompt)
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error {
                    // Fenêtre pleine : nouvelle session avec un résumé des derniers échanges, et on retente une fois.
                    let recap = self.history.suffix(8).map { "\($0.role) : \($0.text)" }.joined(separator: "\n")
                    let fresh = self.makeSession(recap: recap)
                    self.session = fresh
                    text = (try? await self.generate(session: fresh, prompt: prompt)) ?? ""
                } else if !Task.isCancelled {
                    self.callbacks.onError("Apple AI : \(error.localizedDescription)")
                }
            } catch {
                if !Task.isCancelled { self.callbacks.onError("Apple AI : \(error.localizedDescription)") }
            }
            let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !final.isEmpty {
                self.history.append(("Toi", final))
                if self.history.count > 30 { self.history.removeFirst(self.history.count - 30) }
                self.callbacks.onTextDone(final)
            }
            await MainActor.run {
                self.responding = false
                self.callbacks.onResponseDone()
                self.pump()
            }
        }
    }

    /// Génération en flux : chaque morceau nouveau part en delta (lu phrase par phrase par la voix Apple).
    private func generate(session: LanguageModelSession, prompt: String) async throws -> String {
        var last = ""
        let stream = session.streamResponse(to: prompt)
        for try await snapshot in stream {
            let text = snapshot.content
            guard text.count > last.count, text.hasPrefix(last) else { last = text; continue }
            let delta = String(text.dropFirst(last.count))
            last = text
            if !delta.isEmpty { callbacks.onTextDelta(delta) }
        }
        return last
    }

    // MARK: Écoute (reconnaissance vocale iOS, sur l'appareil)

    func appendAudio(_ pcm16: Data) {
        guard isConnected, let request, !coachSpeaking else { return }
        let frames = AVAudioFrameCount(pcm16.count / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        pcm16.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let dst = buffer.int16ChannelData?[0] {
                memcpy(dst, base, Int(frames) * 2)
            }
        }
        request.append(buffer)
    }

    private func startRecognition() {
        guard let recognizer, recognizer.isAvailable else { callbacks.onError("Reconnaissance vocale française indisponible sur cet iPhone."); return }
        stopRecognition(keepTimer: true)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        partial = ""
        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.isConnected else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty { self.heard(text, final: result.isFinal) }
                    if result.isFinal { self.restartRecognition() }
                } else if error != nil {
                    // Fin de tâche (durée, silence) : on relance sans bruit.
                    self.restartRecognition()
                }
            }
        }
        // La reconnaissance continue n'aime pas les très longues requêtes : on repart toutes les 50 s hors parole.
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            guard let self, !self.userSpeaking else { return }
            self.restartRecognition()
        }
    }

    private func restartRecognition() {
        guard isConnected else { return }
        startRecognition()
    }

    private func stopRecognition(keepTimer: Bool = false) {
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        if !keepTimer { restartTimer?.invalidate(); restartTimer = nil }
        utteranceTimer?.invalidate(); utteranceTimer = nil
    }

    /// Une phrase se termine quand la transcription est finale, ou après 1,2 s sans nouveau mot.
    private func heard(_ text: String, final: Bool) {
        if !userSpeaking { userSpeaking = true; callbacks.onSpeechStarted() }
        partial = text
        utteranceTimer?.invalidate()
        if final { finishUtterance(); return }
        utteranceTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.finishUtterance()
            self?.restartRecognition()
        }
    }

    private func finishUtterance() {
        utteranceTimer?.invalidate(); utteranceTimer = nil
        guard userSpeaking else { return }
        userSpeaking = false
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        callbacks.onSpeechStopped()
        // Moins de deux mots : souffle, bruit, ou l'écho d'une phrase de Jeffrey.
        guard text.split(separator: " ").count >= 2 else { return }
        callbacks.onUserTranscript(text)
        queue.append(.user(text))
        pump()
    }

    // MARK: Outils (mêmes noms et arguments que côté OpenAI : `CoachSession.handleFunctionCall` ne change pas)

    private func makeTools(admin: Bool) -> [any Tool] {
        let bridge = Bridge { [weak self] name, args in await self?.callTool(name, args) ?? "{}" }
        var list: [any Tool] = [StartTimerTool(bridge: bridge), CancelTimerTool(bridge: bridge), GetTimeTool(bridge: bridge), SetGoalTool(bridge: bridge),
                                RemindMeTool(bridge: bridge), SaveNoteTool(bridge: bridge), ShowOnWatchTool(bridge: bridge),
                                SuggestWorkoutsTool(bridge: bridge), StartWorkoutTool(bridge: bridge), EndSessionTool(bridge: bridge)]
        // Journal de séance : uniquement pour l'administrateur, comme côté OpenAI.
        if admin { list.append(GetSessionLogTool(bridge: bridge)) }
        return list
    }

    private func callTool(_ name: String, _ args: [String: Any]) async -> String {
        toolCounter += 1
        let callId = "apple_\(toolCounter)"
        let json = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            lock.lock(); toolWaiters[callId] = c; lock.unlock()
            callbacks.onFunctionCall(name, callId, json)
        }
    }

    /// Passe-plat entre un outil Foundation Models et la séance.
    final class Bridge: @unchecked Sendable {
        let call: (String, [String: Any]) async -> String
        init(call: @escaping (String, [String: Any]) async -> String) { self.call = call }
    }
}

// MARK: - Définitions d'outils Foundation Models

private struct StartTimerTool: Tool {
    let name = "start_timer"
    let description = "Lancer le chronomètre de l'application : l'app sonne et prévient quand il se termine. Pour un fractionné, seconds = bloc de travail, rest_seconds = récupération, repeats = nombre de répétitions."
    let bridge: AppleCoachLink.Bridge
    @Generable struct Arguments {
        @Guide(description: "Durée du bloc en secondes (ou du bloc de travail si repeats > 1)") var seconds: Int
        @Guide(description: "Nom court du bloc : sprint, récup, plateau, marche…") var label: String
        @Guide(description: "Récupération entre répétitions en secondes, 0 si aucune") var rest_seconds: Int
        @Guide(description: "Nombre de répétitions, 1 par défaut") var repeats: Int
    }
    func call(arguments a: Arguments) async throws -> String {
        await bridge.call(name, ["seconds": a.seconds, "label": a.label, "rest_seconds": a.rest_seconds, "repeats": max(1, a.repeats)])
    }
}

private struct CancelTimerTool: Tool {
    let name = "cancel_timer"
    let description = "Arrêter le chronomètre en cours (et le programme s'il y en a un)."
    let bridge: AppleCoachLink.Bridge
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String { await bridge.call(name, [:]) }
}

private struct GetTimeTool: Tool {
    let name = "get_time"
    let description = "Lire l'heure exacte de la séance : temps écoulé, restant sur l'objectif, chronomètre en cours."
    let bridge: AppleCoachLink.Bridge
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String { await bridge.call(name, [:]) }
}

private struct SetGoalTool: Tool {
    let name = "set_goal"
    let description = "Changer l'objectif de la séance après accord oral du sportif : kind duration (minutes), distance (kilomètres) ou free."
    let bridge: AppleCoachLink.Bridge
    @Generable struct Arguments {
        @Guide(description: "duration, distance ou free", .anyOf(["duration", "distance", "free"])) var kind: String
        @Guide(description: "Minutes si duration, kilomètres si distance, 0 si free") var target: Double
        @Guide(description: "Pourquoi, en une phrase courte") var reason: String
    }
    func call(arguments a: Arguments) async throws -> String {
        await bridge.call(name, ["kind": a.kind, "target": a.target, "reason": a.reason])
    }
}

private struct RemindMeTool: Tool {
    let name = "remind_me"
    let description = "Rappel unique demandé par le sportif (« préviens-moi dans 5 minutes »). L'app compte et te relance à l'échéance."
    let bridge: AppleCoachLink.Bridge
    @Generable struct Arguments {
        @Guide(description: "Délai en secondes, de 5 à 3600") var seconds: Int
        @Guide(description: "Ce que tu diras au déclenchement, en quelques mots") var reason: String
    }
    func call(arguments a: Arguments) async throws -> String {
        await bridge.call(name, ["seconds": a.seconds, "reason": a.reason])
    }
}

private struct SaveNoteTool: Tool {
    let name = "save_note"
    let description = "Enregistrer une note : kind memory pour un fait durable sur le sportif à retenir, kind feedback pour une remarque au développeur."
    let bridge: AppleCoachLink.Bridge
    @Generable struct Arguments {
        @Guide(description: "memory ou feedback", .anyOf(["memory", "feedback"])) var kind: String
        @Guide(description: "La note, une ou deux phrases, à la troisième personne pour memory") var text: String
    }
    func call(arguments a: Arguments) async throws -> String { await bridge.call(name, ["kind": a.kind, "text": a.text]) }
}

private struct ShowOnWatchTool: Tool {
    let name = "show_on_watch"
    let description = "Afficher en grand sur la montre : what zone (avec zone 1 à 5), pace (avec pace m:ss) ou clear pour revenir à l'écran normal. La montre n'affiche jamais tes phrases."
    let bridge: AppleCoachLink.Bridge
    @Generable struct Arguments {
        @Guide(description: "zone, pace ou clear", .anyOf(["zone", "pace", "clear"])) var what: String
        @Guide(description: "Zone 1 à 5 pour what=zone, sinon 0") var zone: Int
        @Guide(description: "Allure m:ss par km pour what=pace, sinon vide") var pace: String
    }
    func call(arguments a: Arguments) async throws -> String {
        var args: [String: Any] = ["what": a.what]
        if a.zone > 0 { args["zone"] = a.zone }
        if !a.pace.isEmpty { args["pace"] = a.pace }
        return await bridge.call(name, args)
    }
}

private struct SuggestWorkoutsTool: Tool {
    let name = "suggest_workouts"
    let description = "Quand le sportif demande des exercices ou un programme : renvoie deux séances types adaptées au sport et au niveau (beginner, amateur, confirmed)."
    let bridge: AppleCoachLink.Bridge
    @Generable struct Arguments {
        @Guide(description: "beginner, amateur ou confirmed", .anyOf(["beginner", "amateur", "confirmed"])) var level: String
    }
    func call(arguments a: Arguments) async throws -> String { await bridge.call(name, ["level": a.level]) }
}

private struct EndSessionTool: Tool {
    let name = "end_session"
    let description = "Terminer la séance quand le sportif l'a demandé ET confirmé à l'oral. confirmed=false si tu n'as pas encore sa confirmation : l'app te dira de la demander."
    let bridge: AppleCoachLink.Bridge
    @Generable struct Arguments {
        @Guide(description: "true seulement après confirmation orale du sportif") var confirmed: Bool
    }
    func call(arguments a: Arguments) async throws -> String { await bridge.call(name, ["confirmed": a.confirmed]) }
}

private struct GetSessionLogTool: Tool {
    let name = "get_session_log"
    let description = "Lire ton propre journal de séance (l'utilisateur est administrateur). À appeler quand il demande de regarder les logs, ce qui s'est passé, pourquoi tu n'as pas répondu, ce qu'il a dit, l'état de la montre ou de la connexion. Renvoie un instantané de la séance et des lignes horodatées mm:ss."
    let bridge: AppleCoachLink.Bridge
    @Generable struct Arguments {
        @Guide(description: "events (journal technique), errors, tools, watch, dialogue (ce qu'il a dit et ce que tu as dit) ou all", .anyOf(["events", "errors", "tools", "watch", "dialogue", "all"])) var scope: String
        @Guide(description: "Mot-clé pour filtrer, vide sinon") var query: String
        @Guide(description: "Ne garder que les N dernières minutes, 0 pour tout") var since_minutes: Int
    }
    func call(arguments a: Arguments) async throws -> String {
        var args: [String: Any] = ["scope": a.scope, "count": 20]
        if !a.query.isEmpty { args["query"] = a.query }
        if a.since_minutes > 0 { args["since_minutes"] = Double(a.since_minutes) }
        return await bridge.call(name, args)
    }
}

private struct StartWorkoutTool: Tool {
    let name = "start_workout"
    let description = "Lancer la séance type qu'il a choisie (id de suggest_workouts), uniquement après avoir reformulé son choix et obtenu son oui (confirmed=true). L'app enchaîne les blocs et te prévient à chaque changement. Un programme en cours ne se remplace qu'après son accord (replace=true)."
    let bridge: AppleCoachLink.Bridge
    @Generable struct Arguments {
        @Guide(description: "Identifiant de la séance renvoyé par suggest_workouts") var id: String
        @Guide(description: "true seulement après qu'il a confirmé ton récapitulatif") var confirmed: Bool
        @Guide(description: "true seulement après son accord pour abandonner l'enchaînement en cours") var replace: Bool
    }
    func call(arguments a: Arguments) async throws -> String { await bridge.call(name, ["id": a.id, "confirmed": a.confirmed, "replace": a.replace]) }
}
