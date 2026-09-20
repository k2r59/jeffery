import Foundation
import AVFAudio
import CoreLocation
import CoreMotion
import Combine

/// État de la configuration de Jeffrey : ce qui est prêt, ce qui manque, et les demandes d'autorisation faites
/// une à une, dans leur contexte (onboarding pas à pas, puis carte « Configuration » de l'onglet Jeffrey).
@MainActor
final class SetupState: NSObject, ObservableObject {
    enum Status: Equatable {
        case unknown      // jamais demandé
        case ok           // prêt
        case missing      // demandé mais pas obtenu (refus, montre absente, clé invalide)
        case checking     // vérification en cours
    }

    @Published private(set) var health: Status = .unknown
    @Published private(set) var watch: Status = .unknown
    /// Montre jumelée mais sans l'app Jeffrey : le message change.
    @Published private(set) var watchPairedWithoutApp = false
    @Published private(set) var microphone: Status = .unknown
    @Published private(set) var location: Status = .unknown
    @Published private(set) var motion: Status = .unknown
    /// Accès à OpenAI : compte Jeffrey autorisé, ou clé perso.
    @Published private(set) var access: Status = .unknown
    @Published private(set) var apiKey: Status = .unknown
    @Published private(set) var apiKeyError: String?
    /// Niveau du micro (0…1) pendant l'essai de l'étape « Ta voix ».
    @Published private(set) var micLevel: Double = 0
    @Published private(set) var micHeard = false

    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<Void, Never>?
    private var meter: AVAudioRecorder?
    private var meterTimer: Timer?

    override init() {
        super.init()
        locationManager.delegate = self
        refresh()
    }

    /// Relit tout ce qui se lit sans demander : autorisations déjà accordées, clé présente.
    func refresh() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: microphone = .ok
        case .denied: microphone = .missing
        default: microphone = .unknown
        }
        refreshLocation()
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: motion = .ok
        case .denied, .restricted: motion = .missing
        default: motion = CMMotionActivityManager.isActivityAvailable() ? .unknown : .ok
        }
        let key = KeychainStore.read(KeychainStore.apiKeyAccount) ?? ""
        if apiKey != .ok, apiKey != .checking { apiKey = key.isEmpty ? .unknown : .ok }
        refreshAccess()
        if UserDefaults.standard.integer(forKey: Prefs.age) > 0, UserDefaults.standard.double(forKey: Prefs.weightKg) > 0 { health = .ok }
    }

    func refreshAccess() {
        let account = AccountStore.shared
        if let u = account.user, account.isSignedIn {
            access = u.canUse ? .ok : .missing
        } else {
            access = apiKey == .ok ? .ok : .unknown
        }
    }

    private func refreshLocation() {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: location = .ok
        case .denied, .restricted: location = .missing
        default: location = .unknown
        }
    }

    /// Montre : jumelée, app installée. Se met à jour au fil des notifications WatchConnectivity.
    func updateWatch(paired: Bool, installed: Bool) {
        #if DEBUG
        if FakeWatch.enabled { watch = .ok; watchPairedWithoutApp = false; return }
        #endif
        watchPairedWithoutApp = paired && !installed
        watch = paired && installed ? .ok : .missing
    }

    // MARK: Demandes

    func requestHealth() async {
        health = .checking
        let r = await HealthProfile.fetch()
        let d = UserDefaults.standard
        if let a = r.age { d.set(a, forKey: Prefs.age) }
        if let h = r.heightCm { d.set(h, forKey: Prefs.heightCm) }
        if let w = r.weightKg { d.set(w, forKey: Prefs.weightKg) }
        health = r.age != nil || r.weightKg != nil ? .ok : .missing
    }

    func requestMicrophone() async {
        microphone = .checking
        let ok = await AudioPipeline.requestMicrophonePermission()
        microphone = ok ? .ok : .missing
    }

    func requestLocation() async {
        guard locationManager.authorizationStatus == .notDetermined else { refreshLocation(); return }
        location = .checking
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            locationContinuation = c
            locationManager.requestWhenInUseAuthorization()
        }
        refreshLocation()
    }

    /// Mouvement : la première requête d'activité déclenche la demande système.
    func requestMotion() async {
        guard CMMotionActivityManager.isActivityAvailable() else { motion = .ok; return }
        motion = .checking
        let manager = CMMotionActivityManager()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            manager.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: .main) { _, _ in c.resume() }
        }
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: motion = .ok
        case .denied, .restricted: motion = .missing
        default: motion = .unknown
        }
    }

    /// Clé OpenAI : enregistrée dans le trousseau puis vérifiée par un appel léger (liste des modèles).
    func saveAndCheckApiKey(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-") else { apiKey = .missing; apiKeyError = "Une clé OpenAI commence par sk-"; return }
        apiKey = .checking
        apiKeyError = nil
        #if DEBUG
        if FakeRealtimeBackend.enabled { KeychainStore.write(trimmed, account: KeychainStore.apiKeyAccount); apiKey = .ok; refreshAccess(); return }
        #endif
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models/gpt-realtime")!)
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                KeychainStore.write(trimmed, account: KeychainStore.apiKeyAccount)
                apiKey = .ok
                refreshAccess()
            } else if code == 401 {
                apiKey = .missing; apiKeyError = "Clé refusée par OpenAI : vérifie-la."
            } else {
                // Réponse inattendue (droits restreints sur le modèle…) : on garde la clé, Jeffrey tranchera en séance.
                KeychainStore.write(trimmed, account: KeychainStore.apiKeyAccount)
                apiKey = .ok
                refreshAccess()
            }
        } catch {
            apiKey = .missing; apiKeyError = "Impossible de joindre OpenAI : \(error.localizedDescription)"
        }
    }

    // MARK: Essai micro (niveau)

    func startMicMeter() {
        guard meter == nil else { return }
        micHeard = false
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
        try? session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-test.caf")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return }
        recorder.isMeteringEnabled = true
        recorder.record()
        meter = recorder
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.meter else { return }
                r.updateMeters()
                let db = r.averagePower(forChannel: 0) // −160 … 0
                let level = max(0, min(1, (Double(db) + 50) / 50))
                self.micLevel = level
                if level > 0.45 { self.micHeard = true }
            }
        }
    }

    func stopMicMeter() {
        meterTimer?.invalidate(); meterTimer = nil
        meter?.stop(); meter = nil
        micLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var allReady: Bool {
        let appleAI = UserDefaults.standard.string(forKey: Prefs.aiProvider) == "apple"
        return [health, watch, microphone, location, motion].allSatisfy { $0 == .ok } && (appleAI || access == .ok)
    }
}

extension SetupState: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.refreshLocation()
            if manager.authorizationStatus != .notDetermined { self.locationContinuation?.resume(); self.locationContinuation = nil }
        }
    }
}
