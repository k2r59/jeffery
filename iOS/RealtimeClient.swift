import Foundation

/// Client WebSocket pour l'API Realtime d'OpenAI (modèle `gpt-realtime`, audio PCM16 24 kHz).
final class RealtimeClient: NSObject {
    struct Callbacks {
        var onReady: () -> Void = {}
        var onAudioDelta: (Data) -> Void = { _ in }
        var onAssistantTranscriptDelta: (String) -> Void = { _ in }
        var onAssistantTranscriptDone: (String) -> Void = { _ in }
        var onUserTranscript: (String) -> Void = { _ in }
        var onSpeechStarted: () -> Void = {}
        var onSpeechStopped: () -> Void = {}
        var onResponseStarted: () -> Void = {}
        var onResponseDone: () -> Void = {}
        var onError: (String) -> Void = { _ in }
        var onFunctionCall: (_ name: String, _ callId: String, _ arguments: String) -> Void = { _, _, _ in }
        var onTextDelta: (String) -> Void = { _ in }
        var onTextDone: (String) -> Void = { _ in }
        var onDisconnected: (String) -> Void = { _ in }
    }

    var callbacks = Callbacks()

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var pingTimer: Timer?
    private let sendQueue = DispatchQueue(label: "realtime.send")
    private var closedByUser = false
    private var sessionConfig: [String: Any] = [:]
    /// Une seule transition connecté → déconnecté par connexion (les trois callbacks de fermeture sont fusionnés).
    private var disconnectReported = false
    /// Une seule réponse active à la fois côté serveur : les demandes en trop attendent response.done.
    private var responseActive = false
    private var pendingResponses: [[String: Any]] = []
    private var metricsCounter = 0
    private var lastMetricsItemId: String?

    private(set) var isConnected = false
    #if DEBUG
    private var fake: FakeRealtimeBackend?
    #endif

    // MARK: - Connexion

    func connect(apiKey: String, model: String, sessionConfig: [String: Any]) {
        #if DEBUG
        if FakeRealtimeBackend.enabled {
            closedByUser = false; disconnectReported = false; responseActive = false; pendingResponses.removeAll()
            self.sessionConfig = sessionConfig
            let backend = FakeRealtimeBackend()
            backend.deliver = { [weak self] event in
                guard let data = try? JSONSerialization.data(withJSONObject: event), let text = String(data: data, encoding: .utf8) else { return }
                self?.handle(text: text)
            }
            fake = backend
            backend.start()
            return
        }
        #endif
        // Ferme proprement l'ancienne connexion : pas de socket fantôme facturée ni de callbacks tardifs.
        pingTimer?.invalidate(); pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        closedByUser = false
        disconnectReported = false
        responseActive = false
        pendingResponses.removeAll()
        isConnected = false
        self.sessionConfig = sessionConfig
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        task.resume()
        receiveLoop()
    }

    func disconnect() {
        #if DEBUG
        fake = nil
        #endif
        closedByUser = true
        isConnected = false
        responseActive = false
        pendingResponses.removeAll()
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - Événements client

    func send(_ event: [String: Any]) {
        #if DEBUG
        if let fake { fake.handle(event); return }
        #endif
        guard let task, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        sendQueue.async { [weak self] in
            task.send(.string(text)) { error in
                if let error, let self, !self.closedByUser {
                    self.callbacks.onError("Envoi : \(error.localizedDescription)")
                }
            }
        }
    }

    func updateSession() {
        send(["type": "session.update", "session": sessionConfig])
    }

    func appendAudio(_ pcm16: Data) {
        guard isConnected else { return }
        send(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()])
    }

    /// Injecte du contexte texte (rôle `system` par défaut) sans déclencher de réponse.
    func injectText(_ text: String, role: String = "system", itemId: String? = nil) {
        var item: [String: Any] = [
            "type": "message",
            "role": role,
            "content": [["type": "input_text", "text": text]],
        ]
        if let itemId { item["id"] = itemId }
        send(["type": "conversation.item.create", "item": item])
    }

    /// Ligne [MÉTRIQUES] : on remplace la précédente pour ne pas saturer le contexte du modèle.
    func injectMetrics(_ text: String) {
        metricsCounter += 1
        let id = String(format: "metrics_%04d", metricsCounter)
        if let old = lastMetricsItemId {
            send(["type": "conversation.item.delete", "item_id": old])
        }
        injectText(text, itemId: id)
        lastMetricsItemId = id
    }

    /// Demande une réponse. Le motif est transmis en message système (jamais via `response.instructions`,
    /// qui remplacerait les instructions de session) et une seule réponse est active à la fois.
    func requestResponse(instructions: String? = nil) {
        if let instructions, !instructions.isEmpty { injectText("[CONSIGNE] " + instructions) }
        let event: [String: Any] = ["type": "response.create", "response": [:]]
        sendQueue.async { [weak self] in
            guard let self else { return }
            if self.responseActive { self.pendingResponses.append(event); return }
            self.responseActive = true
            self.sendNow(event)
        }
    }

    private func sendNow(_ event: [String: Any]) {
        #if DEBUG
        if let fake { fake.handle(event); return }
        #endif
        guard let task, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func responseFinished() {
        sendQueue.async { [weak self] in
            guard let self else { return }
            if let next = self.pendingResponses.first {
                self.pendingResponses.removeFirst()
                self.responseActive = true
                self.sendNow(next)
            } else {
                self.responseActive = false
            }
        }
    }

    /// Renvoie le résultat d'un appel de fonction, puis laisse le modèle réagir (après la réponse en cours).
    func sendFunctionOutput(callId: String, output: [String: Any], thenRespond: Bool = true) {
        let text = (try? JSONSerialization.data(withJSONObject: output)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        send(["type": "conversation.item.create",
              "item": ["type": "function_call_output", "call_id": callId, "output": text]])
        if thenRespond { requestResponse() }
    }

    func cancelPendingResponses() {
        sendQueue.async { [weak self] in self?.pendingResponses.removeAll() }
    }

    func cancelResponse() {
        send(["type": "response.cancel"])
    }

    // MARK: - Réception

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.reportDisconnect(error.localizedDescription)
            case .success(let message):
                switch message {
                case .string(let text): self.handle(text: text)
                case .data(let data): if let text = String(data: data, encoding: .utf8) { self.handle(text: text) }
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    private func reportDisconnect(_ reason: String) {
        isConnected = false
        responseActive = false
        pendingResponses.removeAll()
        guard !closedByUser, !disconnectReported else { return }
        disconnectReported = true
        callbacks.onDisconnected(reason)
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "session.created":
            isConnected = true
            updateSession()
        case "session.updated":
            callbacks.onReady()
        case "response.created":
            sendQueue.async { [weak self] in self?.responseActive = true }
            callbacks.onResponseStarted()
        case "response.output_audio.delta", "response.audio.delta":
            if let b64 = json["delta"] as? String, let audio = Data(base64Encoded: b64) {
                callbacks.onAudioDelta(audio)
            }
        case "response.output_text.delta", "response.text.delta":
            if let delta = json["delta"] as? String { callbacks.onTextDelta(delta) }
        case "response.output_text.done", "response.text.done":
            callbacks.onTextDone(json["text"] as? String ?? "")
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let delta = json["delta"] as? String { callbacks.onAssistantTranscriptDelta(delta) }
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            callbacks.onAssistantTranscriptDone(json["transcript"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            if let t = json["transcript"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty {
                callbacks.onUserTranscript(t)
            }
        case "response.function_call_arguments.done":
            if let name = json["name"] as? String, let callId = json["call_id"] as? String {
                callbacks.onFunctionCall(name, callId, json["arguments"] as? String ?? "{}")
            }
        case "input_audio_buffer.speech_started":
            callbacks.onSpeechStarted()
        case "input_audio_buffer.speech_stopped":
            callbacks.onSpeechStopped()
        case "response.done":
            if let response = json["response"] as? [String: Any],
               let status = response["status"] as? String, status == "failed",
               let details = response["status_details"] as? [String: Any],
               let error = details["error"] as? [String: Any] {
                callbacks.onError(error["message"] as? String ?? "réponse en échec")
            }
            responseFinished()
            callbacks.onResponseDone()
        case "error":
            let err = json["error"] as? [String: Any]
            let code = err?["code"] as? String ?? ""
            // Erreurs transitoires connues : on ne dérange pas l'utilisateur.
            if code == "conversation_already_has_active_response" { responseFinishedIfIdle(); return }
            callbacks.onError(err?["message"] as? String ?? text)
        default:
            break
        }
    }

    private func responseFinishedIfIdle() {
        // Le serveur refuse une seconde réponse : la nôtre repartira sur le prochain response.done.
    }

    private func startPing() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                self?.task?.sendPing { _ in }
            }
        }
    }
}

extension RealtimeClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        startPing()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return } // callback d'une ancienne connexion
        let text = reason.flatMap { String(data: $0, encoding: .utf8) }.map { "\($0) (code \(closeCode.rawValue))" } ?? "fermeture serveur, code \(closeCode.rawValue)"
        reportDisconnect(text)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task, let error else { return }
        reportDisconnect(error.localizedDescription)
    }
}
