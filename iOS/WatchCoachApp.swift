import SwiftUI

@main
struct WatchCoachApp: App {
    @StateObject private var coach = CoachSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coach)
        }
    }
}
