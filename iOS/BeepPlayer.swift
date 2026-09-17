import Foundation
import AVFoundation

/// Lecteur minimal de bips (PCM16 mono 24 kHz) quand la file audio de Jeffrey n'est pas utilisée.
final class BeepPlayer {
    static let shared = BeepPlayer()
    private var player: AVAudioPlayer?

    func play(pcm16: Data) {
        var wav = Data()
        func append<T: FixedWidthInteger>(_ v: T) { var le = v.littleEndian; wav.append(Data(bytes: &le, count: MemoryLayout<T>.size)) }
        wav.append("RIFF".data(using: .ascii)!); append(UInt32(36 + pcm16.count)); wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(24_000)); append(UInt32(48_000)); append(UInt16(2)); append(UInt16(16))
        wav.append("data".data(using: .ascii)!); append(UInt32(pcm16.count)); wav.append(pcm16)
        player = try? AVAudioPlayer(data: wav)
        player?.play()
    }
}
