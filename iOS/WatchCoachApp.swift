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
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coach)
        }
    }
}
