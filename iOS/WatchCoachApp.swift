import SwiftUI

@main
struct WatchCoachApp: App {
    @StateObject private var coach = CoachSession()

    init() {
        #if DEBUG
        // Tests d'interface : repartir d'une app vierge (réglages effacés) sans dépendre du domaine d'arguments,
        // qui masquerait ensuite ce que l'onboarding écrit.
        if ProcessInfo.processInfo.environment["WATCHCOACH_RESET"] == "1", let bundle = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundle)
            _ = KeychainStore.delete(KeychainStore.apiKeyAccount)
        }
        // Tests d'interface : quelques séances avec ressenti dans le journal.
        if ProcessInfo.processInfo.environment["WATCHCOACH_SEED_SESSIONS"] == "1" {
            let rows: [SessionSummary] = [
                SessionSummary(id: "seed-1", date: Date().addingTimeInterval(-86_400), kind: .running, elapsed: 1860, distance: 5200,
                               averageHeartRate: 150, maxHeartRate: 172, feeling: .good, goalLabel: "5 km", goalReached: true, lastCoachLine: nil),
                SessionSummary(id: "seed-2", date: Date().addingTimeInterval(-3 * 86_400), kind: .walking, elapsed: 2400, distance: 3100,
                               averageHeartRate: 110, maxHeartRate: 130, feeling: .easy, lastCoachLine: nil),
                SessionSummary(id: "seed-3", date: Date().addingTimeInterval(-5 * 86_400), kind: .running, elapsed: 2700, distance: 6800,
                               averageHeartRate: 160, maxHeartRate: 181, feeling: .intense, goalLabel: "45 min", goalReached: true, lastCoachLine: nil),
                SessionSummary(id: "seed-4", date: Date().addingTimeInterval(-8 * 86_400), kind: .running, elapsed: 1500, distance: 4000,
                               averageHeartRate: 148, maxHeartRate: 170, feeling: nil, goalLabel: "25 min", goalReached: false, lastCoachLine: nil),
            ]
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            if let data = try? e.encode(rows) { try? data.write(to: SessionSummary.fileURL, options: .atomic) }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coach)
        }
    }
}
