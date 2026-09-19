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

    /// Gain appliqué à la voix (écrêtage doux au-delà de 1.0) pour passer au-dessus de la musique.
    var gain: Float = 1.0

    func append(pcm16 data: Data) {
        let count = data.count / 2
        guard count > 0 else { return }
        var floats = [Float](repeating: 0, count: count)
        let g = gain
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let v = Float(Int16(littleEndian: src[i])) / 32768 * g
                floats[i] = g > 1 ? tanh(v) : v
            }
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
    private var restartTask: DispatchWorkItem?

    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    /// Appelé sur le thread audio avec des trames PCM16 LE 24 kHz mono.
    var onCapturedPCM16: ((Data) -> Void)?
    var onRouteChanged: ((String) -> Void)?

    var isPlaying: Bool { playback.available > 0 }

    /// Niveau de la voix de Jeffrey (1.0 = tel quel ; 1.8 = nettement au-dessus de la musique).
    var voiceGain: Float {
        get { playback.gain }
        set { playback.gain = newValue }
    }

    func start() throws {
        try configureSession()
        try startEngine()
        installObservers()
        isRunning = true
    }

    func stop() {
        isRunning = false
        restartTask?.cancel(); restartTask = nil
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

    /// Niveau RMS (0-1) sous lequel la trame est remplacée par du silence (anti-souffle, anti-vent).
    var noiseGate: Float = 0.015
    private var gateHold = 0

    /// Micro : écouteurs Bluetooth (mains libres, musique en qualité téléphone) ou micro de l'iPhone (musique en pleine qualité).
    var useHeadsetMic = true
    /// Changement de catégorie déclenché par nous : l'observateur de route ne doit pas redémarrer le moteur.
    private var internalCategoryChange = false

    /// Atténuer la musique des autres apps pendant que le coach parle.
    var duckOthersWhileSpeaking = true
    private var ducking = false

    private var baseOptions: AVAudioSession.CategoryOptions {
        // .mixWithOthers : la musique (Apple Music, Spotify…) continue pendant la séance.
        // Sans HFP, la sortie reste en A2DP (pleine qualité) et le micro est celui de l'iPhone.
        useHeadsetMic ? [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
                      : [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
    }

    /// Demande la permission micro (à faire avant `start`, l'app au premier plan).
    static func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private func applyCategory(duck: Bool) throws {
        var options = baseOptions
        if duck { options.insert(.duckOthers) }
        // .voiceChat active l'annulation d'écho : indispensable pour que le coach ne s'entende pas lui-même.
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: options)
    }

    /// Active ou retire l'atténuation des autres apps (appelé quand le coach commence / finit de parler).
    private var unduckTask: DispatchWorkItem?

    func setDucking(_ on: Bool) {
        guard isRunning, duckOthersWhileSpeaking || !on else { return }
        unduckTask?.cancel()
        if !on {
            // On garde la musique basse encore 1,5 s après la phrase : pas de pompage entre deux phrases proches.
            let task = DispatchWorkItem { [weak self] in self?.applyDucking(false) }
            unduckTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
            return
        }
        applyDucking(true)
    }

    private func applyDucking(_ on: Bool) {
        guard on != ducking else { return }
        ducking = on
        internalCategoryChange = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.applyCategory(duck: on)
                // La réactivation applique le nouveau réglage aux autres apps (retour du volume quand on cesse d'atténuer).
                try AVAudioSession.sharedInstance().setActive(true, options: [])
            } catch {
                // Sans gravité : la musique reste à son niveau.
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.internalCategoryChange = false }
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        ducking = false
        try applyCategory(duck: false)
        try session.setPreferredSampleRate(24_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
        if !useHeadsetMic, let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }

    /// Exception Objective-C d'AVFAudio (format de tap qui ne colle plus au matériel après un changement de route,
    /// moteur pas prêt) rendue comme une erreur Swift au lieu d'un abort de l'app.
    private func guarded(_ what: String, _ block: () -> Void) throws {
        do { try ObjCExceptionCatcher.run(block) } catch {
            throw NSError(domain: "AudioPipeline", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "\(what) : \(error.localizedDescription)"])
        }
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
        // Format nil : le tap prend le format courant du nœud, jamais un format lu avant un changement de route
        // (le convertisseur suit dans handleCaptured si le format des trames diffère). Variante iOS 27 qui
        // renvoie une erreur au lieu de lever une exception (plantage du 19/09 sur un changement d'écouteurs).
        try input.installAudioTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            self?.handleCaptured(AVAudioPCMBuffer(copying: buffer))
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
            try engine.connectNode(node, to: engine.mainMixerNode, format: playbackFormat)
            sourceNode = node
        }
        engine.prepare()
        var startError: Error?
        try guarded("démarrage du moteur audio") {
            do { try engine.start() } catch { startError = error }
        }
        if let startError { throw startError }
    }

    /// Après un changement de route ou une remise à zéro du serveur audio : le matériel met un instant à se
    /// stabiliser, on relance un peu plus tard et on réessaie deux fois avant d'abandonner (l'app survit dans tous les cas).
    private func scheduleRestart(rebuildSession: Bool, attempt: Int = 0) {
        restartTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            do {
                if rebuildSession { try self.configureSession() }
                try self.startEngine()
                let name = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "micro"
                self.onRouteChanged?(name)
            } catch {
                if attempt < 2 {
                    self.scheduleRestart(rebuildSession: rebuildSession, attempt: attempt + 1)
                } else {
                    self.onRouteChanged?("erreur audio : \(error.localizedDescription)")
                }
            }
        }
        restartTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.3 : 0.8), execute: task)
    }

    private func handleCaptured(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: captureFormat)
        }
        guard let converter else { return }
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
        let count = Int(out.frameLength)
        if noiseGate > 0 {
            var acc: Float = 0
            for i in 0..<count { let v = Float(channel[0][i]) / 32768; acc += v * v }
            let rms = (acc / Float(count)).squareRoot()
            // Hystérésis : on garde le micro ouvert ~300 ms après la dernière trame au-dessus du seuil.
            if rms >= noiseGate { gateHold = 4 } else if gateHold > 0 { gateHold -= 1 }
            if gateHold == 0 {
                onCapturedPCM16?(Data(count: count * MemoryLayout<Int16>.size))
                return
            }
        }
        let data = Data(bytes: channel[0], count: count * MemoryLayout<Int16>.size)
        onCapturedPCM16?(data)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            // Le serveur audio a redémarré : tout est à reconstruire.
            self.engine.stop()
            self.engine.inputNode.removeTap(onBus: 0)
            if let node = self.sourceNode { self.engine.detach(node) }
            self.sourceNode = nil
            self.scheduleRestart(rebuildSession: true)
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { self.playback.clear() }
            if type == .ended, self.isRunning {
                try? AVAudioSession.sharedInstance().setActive(true, options: [])
                try? self.engine.start()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.isRunning, let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || (reason == .categoryChange && !self.internalCategoryChange) else { return }
            // Le format d'entrée change avec la route (AirPods ↔ micro interne) : on réinstalle la capture, un
            // instant plus tard, le temps que le matériel se stabilise (plantage du 19/09 : tap installé trop tôt).
            self.engine.stop()
            self.scheduleRestart(rebuildSession: false)
        })
    }
}
