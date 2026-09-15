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
        var onDisconnected: (String) -> Void = { _ in }
    }

    var callbacks = Callbacks()

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var pingTimer: Timer?
    private let sendQueue = DispatchQueue(label: "realtime.send")
    private var closedByUser = false
    private var sessionConfig: [String: Any] = [:]

    private(set) var isConnected = false

    // MARK: - Connexion

    func connect(apiKey: String, model: String, sessionConfig: [String: Any]) {
        closedByUser = false
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
        closedByUser = true
        isConnected = false
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - Événements client

    func send(_ event: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        sendQueue.async {
            task.send(.string(text)) { [weak self] error in
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
    func injectText(_ text: String, role: String = "system") {
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": role,
                "content": [["type": "input_text", "text": text]],
            ],
        ])
    }

    func requestResponse(instructions: String? = nil) {
        var response: [String: Any] = [:]
        if let instructions { response["instructions"] = instructions }
        send(["type": "response.create", "response": response])
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
                self.isConnected = false
                if !self.closedByUser { self.callbacks.onDisconnected(error.localizedDescription) }
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
            callbacks.onResponseStarted()
        case "response.output_audio.delta", "response.audio.delta":
            if let b64 = json["delta"] as? String, let audio = Data(base64Encoded: b64) {
                callbacks.onAudioDelta(audio)
            }
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let delta = json["delta"] as? String { callbacks.onAssistantTranscriptDelta(delta) }
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            callbacks.onAssistantTranscriptDone(json["transcript"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            if let t = json["transcript"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty {
                callbacks.onUserTranscript(t)
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
            callbacks.onResponseDone()
        case "error":
            let err = json["error"] as? [String: Any]
            callbacks.onError(err?["message"] as? String ?? text)
        default:
            break
        }
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
        isConnected = false
        guard !closedByUser else { return }
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "code \(closeCode.rawValue)"
        callbacks.onDisconnected(text)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !closedByUser else { return }
        isConnected = false
        callbacks.onDisconnected(error.localizedDescription)
    }
}
