import Foundation
import AVFoundation
import Combine

/// Voix de synthèse Apple (neuronales = qualité Premium, sinon Enhanced) : aperçu local, sans réseau ni clé.
@MainActor
final class AppleVoice: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var voices: [AVSpeechSynthesisVoice] = []
    @Published var selectedIdentifier: String = UserDefaults.standard.string(forKey: "apple.voice") ?? ""

    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [String] = []
    /// Appelé quand la file est vide et que la dernière phrase est finie.
    var onIdle: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        refresh()
    }

    func refresh() {
        // Voix françaises, meilleures qualités d'abord (Premium = neuronale, Enhanced = améliorée, Default = compacte).
        voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("fr") }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
        if selectedIdentifier.isEmpty || !voices.contains(where: { $0.identifier == selectedIdentifier }) {
            selectedIdentifier = voices.first?.identifier ?? ""
        }
    }

    var selected: AVSpeechSynthesisVoice? { voices.first { $0.identifier == selectedIdentifier } }

    static func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: return "Premium (neuronale)"
        case .enhanced: return "Améliorée"
        default: return "Compacte"
        }
    }

    /// Aperçu isolé (hors séance) : configure la session audio en lecture simple.
    func speak(_ text: String) {
        guard selected != nil else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        stop()
        enqueue(text)
    }

    /// En séance : ajoute une phrase à lire (la session audio est déjà gérée par AudioPipeline).
    func enqueue(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let voice = selected else { return }
        UserDefaults.standard.set(voice.identifier, forKey: "apple.voice")
        queue.append(t)
        if !synthesizer.isSpeaking { speakNext() }
    }

    private func speakNext() {
        guard let voice = selected, !queue.isEmpty else {
            isSpeaking = false
            onIdle?()
            return
        }
        let text = queue.removeFirst()
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        u.pitchMultiplier = 1.0
        u.postUtteranceDelay = 0.05
        isSpeaking = true
        synthesizer.speak(u)
    }

    func stop() {
        queue.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}

extension AppleVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakNext() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
