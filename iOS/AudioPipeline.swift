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
        onAudioEvent?(routeDescription())
        watchOtherAudio()
    }

    /// Événements audio pour le journal : liaison des écouteurs, décrochages, musique des autres apps.
    var onAudioEvent: ((String) -> Void)?

    /// « sortie AirPods Pro (Bluetooth A2DP) · entrée AirPods Pro (Bluetooth HFP) · Bluetooth haute qualité : actif ».
    func routeDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        func port(_ p: AVAudioSessionPortDescription?) -> String { p.map { "\($0.portName) (\($0.portType.rawValue))" } ?? "aucune" }
        var text = "sortie \(port(route.outputs.first)) · entrée \(port(route.inputs.first))"
        if let hq = route.inputs.first?.bluetoothMicrophoneExtension?.highQualityRecording {
            text += " · Bluetooth haute qualité : \(hq.isEnabled ? "actif" : (hq.isSupported ? "inactif" : "non supporté"))"
        }
        return text
    }

    /// Musique d'une autre app : notée au départ puis à chaque arrêt ou reprise (preuve qu'on ne la coupe pas).
    private var otherAudioTimer: Timer?
    private func watchOtherAudio() {
        otherAudioTimer?.invalidate()
        var playing = AVAudioSession.sharedInstance().isOtherAudioPlaying
        onAudioEvent?("musique d'une autre app : \(playing ? "en cours" : "aucune")")
        otherAudioTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let now = AVAudioSession.sharedInstance().isOtherAudioPlaying
            guard now != playing else { return }
            playing = now
            self?.onAudioEvent?("musique d'une autre app : \(now ? "reprise" : "arrêtée")")
        }
    }

    private static func label(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: return "écouteurs branchés"
        case .oldDeviceUnavailable: return "écouteurs débranchés"
        case .categoryChange: return "réglage audio modifié"
        case .override: return "sortie forcée"
        case .wakeFromSleep: return "réveil"
        case .noSuitableRouteForCategory: return "aucune sortie"
        case .routeConfigurationChange: return "configuration"
        default: return "autre"
        }
    }

    func stop() {
        isRunning = false
        otherAudioTimer?.invalidate(); otherAudioTimer = nil
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

    /// Micro : écouteurs Bluetooth ou micro de l'iPhone (musique toujours en pleine qualité).
    var useHeadsetMic = true

    /// Réglage audio posé une seule fois au départ, jamais modifié pendant la séance : chaque changement fait
    /// décrocher un instant les écouteurs Bluetooth, et l'app de musique (Deezer, Spotify…) se met en pause comme
    /// si on les avait retirés, sans reprendre seule (retour de Marie-Laure du 06/10).
    private var sessionOptions: AVAudioSession.CategoryOptions {
        // .mixWithOthers : la musique continue à son niveau, la voix de Jeffrey passe par-dessus.
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
        // Micro des écouteurs : pleine qualité dans les deux sens si les écouteurs le permettent (AirPods récents),
        // sinon repli en mains libres (musique en qualité téléphone).
        if useHeadsetMic { options.formUnion([.bluetoothHighQualityRecording, .allowBluetoothHFP]) }
        return options
    }

    /// Demande la permission micro (à faire avant `start`, l'app au premier plan).
    static func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Mode par défaut : seul compatible avec l'enregistrement Bluetooth haute qualité.
        try session.setCategory(.playAndRecord, mode: .default, options: sessionOptions)
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
            self.onAudioEvent?("changement de route (\(Self.label(reason))) · \(self.routeDescription())")
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .categoryChange else { return }
            // Le format d'entrée change avec la route (AirPods ↔ micro interne) : on réinstalle la capture, un
            // instant plus tard, le temps que le matériel se stabilise (plantage du 19/09 : tap installé trop tôt).
            self.engine.stop()
            self.scheduleRestart(rebuildSession: false)
        })
    }
}
