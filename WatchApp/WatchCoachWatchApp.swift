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
