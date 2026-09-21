import Foundation

/// PCM16 mono → fichier WAV en mémoire (pour AVAudioPlayer).
enum WAV {
    static func data(pcm16: Data, sampleRate: UInt32 = 24_000) -> Data {
        var wav = Data()
        func append<T: FixedWidthInteger>(_ v: T) { var le = v.littleEndian; wav.append(Data(bytes: &le, count: MemoryLayout<T>.size)) }
        wav.append("RIFF".data(using: .ascii)!); append(UInt32(36 + pcm16.count)); wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        wav.append("data".data(using: .ascii)!); append(UInt32(pcm16.count)); wav.append(pcm16)
        return wav
    }
}
