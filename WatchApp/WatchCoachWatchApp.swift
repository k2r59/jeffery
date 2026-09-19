import SwiftUI
import HealthKit
import WatchKit
import WatchConnectivity

@main
struct WatchCoachWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @StateObject private var workout = WorkoutManager.shared

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(workout)
        }
    }
}

/// Reçoit le lancement déclenché depuis l'iPhone (HKHealthStore.startWatchApp).
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        #if DEBUG
        // Aperçu d'une scène sur simulateur : WATCHCOACH_SCENE=countdown|interval|zone|pace|message|climb|ghost|celebration
        if let name = ProcessInfo.processInfo.environment["WATCHCOACH_SCENE"] {
            let scene = WatchScenePreview.scene(named: name)
            var m = CoachMirror.idle
            m.phase = "live"; m.elapsed = 754; m.timestamp = Date(); m.heartRate = 142; m.distance = 2140
            m.goalLabel = "5 km"; m.remaining = "2,86 km"; m.progress = 0.43; m.scene = scene; m.paceSecPerKm = 312
            m.coachSpeaking = ProcessInfo.processInfo.environment["WATCHCOACH_SPEAKING"] == "1"; m.lastLine = "Belle relance, garde ça jusqu'au pont."
            m.zoneSeconds = [40, 180, 310, 150, 74]; m.averageHeartRate = 147; m.energy = 212; m.averageSpeed = 2.84
            Task { @MainActor in WatchMirror.shared.state = m; WatchMirror.shared.phoneReachable = true }
            return
        }
        #endif
        WatchSender.shared.activate()
        WorkoutManager.shared.requestAuthorization()
    }

    func applicationDidBecomeActive() {
        Task { @MainActor in WorkoutManager.shared.appBecameActive() }
    }

    /// Lancement à distance : la commande déposée par l'iPhone dit s'il faut suivre l'app Exercice ou piloter la séance.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        let kind = WorkoutKind(activityType: workoutConfiguration.activityType)
        let context = WCSession.default.receivedApplicationContext
        var companion = false
        if let data = context[WCKeys.command] as? Data,
           let payload = try? WCCodec.decoder.decode(WatchCommandPayload.self, from: data),
           let at = context[WCKeys.commandAt] as? Double,
           Date().timeIntervalSince1970 - at < 180,
           payload.command == .start, payload.mode == .companion {
            companion = true
        }
        Task { @MainActor in
            companion ? WorkoutManager.shared.startCompanion(kind: kind) : WorkoutManager.shared.startOwned(kind: kind)
        }
    }
}

#if DEBUG
enum WatchScenePreview {
    static func scene(named name: String) -> WatchScene? {
        let now = Date()
        switch name {
        case "countdown":
            return WatchScene(kind: .countdown, id: "p1", title: "Marche", subtitle: "puis course · 1 min", startsAt: now.addingTimeInterval(-12), endsAt: now.addingTimeInterval(18), phase: "work")
        case "interval":
            return WatchScene(kind: .interval, id: "p2", title: "Sprint 3/8", subtitle: "récup 30 s ensuite", caption: "Fractionné 30/30 · bloc 2/3", startsAt: now.addingTimeInterval(-8), endsAt: now.addingTimeInterval(22), phase: "work")
        case "zone":
            return WatchScene(kind: .zone, id: "p3", title: "Reste en Z2", subtitle: "cible 130 – 148", low: 130, high: 148, zone: 2)
        case "pace":
            return WatchScene(kind: .pace, id: "p4", title: "Allure cible 5:30", subtitle: "min/km", low: 320, high: 340, value: 312)
        case "message":
            return WatchScene(kind: .message, id: "p5", title: "Jeffrey", subtitle: "Belle relance, garde ça jusqu'au pont.", until: now.addingTimeInterval(60))
        case "climb":
            return WatchScene(kind: .climb, id: "p6", title: "Montée · 6 %", subtitle: "encore +28 m sur 500 m", caption: "Petits pas, bras actifs.", value: 6, progress: 42)
        case "ghost":
            return WatchScene(kind: .ghost, id: "p7", title: "Fantôme · 12 sept.", subtitle: "3,2 km · reste 1,8 km", value: 14, progress: 0.64)
        case "stats", "none":
            return nil
        case "celebration":
            return WatchScene(kind: .celebration, id: "p8", title: "Objectif atteint", subtitle: "5 km · 27:41", until: now.addingTimeInterval(60))
        default: return nil
        }
    }
}
#endif
