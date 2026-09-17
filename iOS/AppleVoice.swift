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

    static func qualityLabel(_ q: AVSpeechSynthesisVoice.Quality) -> String {
        switch q {
        case .premium: return "Premium (neuronale)"
        case .enhanced: return "Améliorée"
        default: return "Compacte"
        }
    }

    func speak(_ text: String) {
        guard let voice = selected else { return }
        UserDefaults.standard.set(voice.identifier, forKey: "apple.voice")
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        synthesizer.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        u.pitchMultiplier = 1.0
        isSpeaking = true
        synthesizer.speak(u)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

extension AppleVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
