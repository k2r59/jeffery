import Foundation
import AVFoundation
import Combine

/// Aperçu d'une voix : une phrase dite par Jeffrey via une session Realtime éphémère, mise en cache par voix.
@MainActor
final class VoicePreview: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var error: String?

    private var client: RealtimeClient?
    private var buffer = Data()
    private var player: AVAudioPlayer?
    private var delegateBox: PlayerDelegate?

    private static func cacheURL(for voice: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("preview-\(voice).pcm")
    }

    func play(voice: String, name: String) {
        error = nil
        if let cached = try? Data(contentsOf: Self.cacheURL(for: voice)), cached.count > 24_000 {
            playPCM(cached)
            return
        }
        let apiKey = KeychainStore.read(KeychainStore.apiKeyAccount) ?? ""
        guard !apiKey.isEmpty else { error = "Clé API manquante"; return }
        guard !isLoading else { return }
        isLoading = true
        buffer = Data()
        let client = RealtimeClient()
        self.client = client
        let model = UserDefaults.standard.string(forKey: Prefs.model) ?? "gpt-realtime"
        client.callbacks.onReady = { [weak self] in
            let who = name.isEmpty ? "" : " \(name),"
            client.requestResponse(instructions: "Dis exactement, naturellement : « Salut\(who) moi c'est Jeffrey. On y va à ton rythme. » Rien d'autre.")
            _ = self
        }
        client.callbacks.onAudioDelta = { [weak self] data in
            Task { @MainActor in self?.buffer.append(data) }
        }
        client.callbacks.onResponseDone = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                self.client?.disconnect()
                self.client = nil
                if self.buffer.count > 24_000 {
                    try? self.buffer.write(to: Self.cacheURL(for: voice), options: .atomic)
                    self.playPCM(self.buffer)
                } else {
                    self.error = "Aperçu vide, réessaie."
                }
            }
        }
        client.callbacks.onError = { [weak self] message in
            Task { @MainActor in
                self?.error = message
                self?.isLoading = false
                self?.client?.disconnect()
                self?.client = nil
            }
        }
        client.callbacks.onDisconnected = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.isLoading else { return }
                self.error = "Connexion : \(reason)"
                self.isLoading = false
            }
        }
        let config: [String: Any] = [
            "type": "realtime",
            "instructions": "Tu es Jeffrey, coach sportif vocal, chaleureux, en français.",
            "output_modalities": ["audio"],
            "audio": [
                "input": ["format": ["type": "audio/pcm", "rate": 24_000], "turn_detection": NSNull()],
                "output": ["format": ["type": "audio/pcm", "rate": 24_000], "voice": voice],
            ],
        ]
        client.connect(apiKey: apiKey, model: model, sessionConfig: config)
    }

    /// PCM16 mono 24 kHz → WAV en mémoire → AVAudioPlayer.
    private func playPCM(_ pcm: Data) {
        var wav = Data()
        func append<T: FixedWidthInteger>(_ v: T) { var le = v.littleEndian; wav.append(Data(bytes: &le, count: MemoryLayout<T>.size)) }
        wav.append("RIFF".data(using: .ascii)!); append(UInt32(36 + pcm.count)); wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(24_000)); append(UInt32(24_000 * 2)); append(UInt16(2)); append(UInt16(16))
        wav.append("data".data(using: .ascii)!); append(UInt32(pcm.count)); wav.append(pcm)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let p = try AVAudioPlayer(data: wav)
            let box = PlayerDelegate { [weak self] in Task { @MainActor in self?.isPlaying = false } }
            delegateBox = box
            p.delegate = box
            player = p
            isPlaying = true
            p.play()
        } catch {
            self.error = "Lecture : \(error.localizedDescription)"
        }
    }

    private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish() }
    }
}
