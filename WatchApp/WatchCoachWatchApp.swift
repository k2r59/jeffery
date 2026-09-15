import SwiftUI
import HealthKit
import WatchKit

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

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        let kind = WorkoutKind(activityType: workoutConfiguration.activityType)
        Task { @MainActor in
            WorkoutManager.shared.startOwned(kind: kind)
        }
    }
}
