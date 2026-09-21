import Foundation
import AVFoundation

/// Lecteur minimal de bips (PCM16 mono 24 kHz) quand la file audio de Jeffrey n'est pas utilisée.
final class BeepPlayer {
    static let shared = BeepPlayer()
    private var player: AVAudioPlayer?

    func play(pcm16: Data) {
        player = try? AVAudioPlayer(data: WAV.data(pcm16: pcm16))
        player?.play()
    }
}
