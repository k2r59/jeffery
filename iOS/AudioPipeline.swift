import Foundation
import AVFoundation

/// File d'échantillons Float32 mono 24 kHz consommée par le nœud de lecture.
final class PCMPlaybackQueue {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var head = 0

    var available: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count - head
    }

    func append(pcm16 data: Data) {
        let count = data.count / 2
        guard count > 0 else { return }
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<count { floats[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        lock.lock()
        samples.append(contentsOf: floats)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        head = 0
        lock.unlock()
    }

    /// Copie `count` échantillons dans `out` (zéros si la file est vide).
    func read(into out: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock()
        let n = min(count, samples.count - head)
        if n > 0 {
            samples.withUnsafeBufferPointer { buf in
                out.update(from: buf.baseAddress! + head, count: n)
            }
            head += n
        }
        if n < count {
            (out + n).update(repeating: 0, count: count - n)
        }
        if head > 24_000 * 10 {
            samples.removeFirst(head)
            head = 0
        }
        lock.unlock()
    }
}

/// Capture micro → PCM16 mono 24 kHz (format Realtime) et lecture des réponses audio du coach.
final class AudioPipeline {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var converter: AVAudioConverter?
    private let playback = PCMPlaybackQueue()
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    /// Appelé sur le thread audio avec des trames PCM16 LE 24 kHz mono.
    var onCapturedPCM16: ((Data) -> Void)?
    var onRouteChanged: ((String) -> Void)?

    var isPlaying: Bool { playback.available > 0 }

    func start() throws {
        try configureSession()
        try startEngine()
        installObservers()
        isRunning = true
    }

    func stop() {
        isRunning = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        playback.clear()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func enqueuePlayback(pcm16 data: Data) {
        playback.append(pcm16: data)
    }

    func stopPlayback() {
        playback.clear()
    }

    // MARK: - Interne

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .voiceChat active l'annulation d'écho : indispensable pour que le coach ne s'entende pas lui-même.
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setPreferredSampleRate(24_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "AudioPipeline", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Entrée micro indisponible (format \(inputFormat))"])
        }
        converter = AVAudioConverter(from: inputFormat, to: captureFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCaptured(buffer)
        }

        if sourceNode == nil {
            let queue = playback
            let node = AVAudioSourceNode(format: playbackFormat) { _, _, frameCount, audioBufferList -> OSStatus in
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard let raw = abl[0].mData else { return noErr }
                queue.read(into: raw.assumingMemoryBound(to: Float.self), count: Int(frameCount))
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: playbackFormat)
            sourceNode = node
        }
        engine.prepare()
        try engine.start()
    }

    private func handleCaptured(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }
        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let data = Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        onCapturedPCM16?(data)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended, self.isRunning {
                try? AVAudioSession.sharedInstance().setActive(true, options: [])
                try? self.engine.start()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.isRunning, let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .categoryChange else { return }
            // Le format d'entrée change avec la route (AirPods ↔ micro interne) : on réinstalle la capture.
            self.engine.stop()
            do {
                try self.startEngine()
                let route = AVAudioSession.sharedInstance().currentRoute
                let name = route.inputs.first?.portName ?? "micro"
                self.onRouteChanged?(name)
            } catch {
                self.onRouteChanged?("erreur audio : \(error.localizedDescription)")
            }
        })
    }
}
