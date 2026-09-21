import SwiftUI

struct RootView: View {
    @EnvironmentObject private var coach: CoachSession
    @AppStorage(Prefs.onboarded) private var onboarded: Bool = false
    @AppStorage(Prefs.setupVersion) private var setupVersion: Int = 0
    @StateObject private var history = WorkoutHistory()
    @State private var tab = 0
    @State private var summaryToShow: SessionSummary?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $tab) {
            TodayView(history: history, goToSessions: { tab = 1 }, goToJeffrey: { tab = 3 })
                .tabItem { Label { Text("Aujourd'hui") } icon: { Image("accueil-creme").renderingMode(.template) } }.tag(0)
            SessionsView(history: history)
                .tabItem { Label { Text("Séances") } icon: { Image("seances-creme").renderingMode(.template) } }.tag(1)
            YouView()
                .tabItem { Label { Text("Toi") } icon: { Image("profil-creme").renderingMode(.template) } }.tag(2)
            JeffreyView()
                .tabItem { Label { Text("Jeffrey") } icon: { Image("voix-creme").renderingMode(.template) } }.tag(3)
        }
        .tint(Theme.lime)
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: Binding(get: { coach.phase != .idle }, set: { _ in }), onDismiss: {
            if let s = coach.endedSummary { coach.endedSummary = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { summaryToShow = s } }
        }) {
            LiveSessionView().environmentObject(coach)
        }
        .sheet(item: $summaryToShow) { summary in SessionEndView(summary: summary) }
        .fullScreenCover(isPresented: Binding(get: { !onboarded || setupVersion < Prefs.currentSetupVersion }, set: { _ in })) { OnboardingView() }
        .task {
            await history.load(); SessionAnalysisService.shared.catchUp()
            // Une séance était en cours quand l'app s'est arrêtée : reprise, ou bilan si elle est trop vieille.
            coach.recoverIfNeeded()
            if coach.phase == .idle, let s = coach.endedSummary { coach.endedSummary = nil; summaryToShow = s }
        }
        .onChange(of: coach.phase) { _, phase in
            if phase == .idle { Task { await history.load() } }
        }
        .onChange(of: scenePhase) { _, p in
            if p == .active { coach.resumeIfWaitingForForeground() }
        }
        .onAppear {
            #if DEBUG
            if let t = ProcessInfo.processInfo.environment["WATCHCOACH_TAB"], let i = Int(t) { tab = i }
            if ProcessInfo.processInfo.environment["WATCHCOACH_AUTOSTART"] == "1", coach.phase == .idle {
                let minutes = Double(ProcessInfo.processInfo.environment["WATCHCOACH_GOAL_MIN"] ?? "2") ?? 2
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    coach.start(kind: .running, goal: SessionGoal(kind: .duration, target: minutes * 60, note: "banc d'essai"))
                }
            }
            // Arrêt programmé, aussi pour une séance reprise après une mort de l'app (banc de test de la reprise).
            let stopAfter = Double(ProcessInfo.processInfo.environment["WATCHCOACH_STOP_AFTER"] ?? "0") ?? 0
            if stopAfter > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter) { coach.stop() } }
            #endif
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(Theme.background)
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

/// En-tête commun : logotype + accroche.
struct JeffreyHeader: View {
    var body: some View {
        HStack(alignment: .top) {
            JeffreyWordmark(size: 26, signature: true)
            Spacer()
        }
    }
}

/// Bulle de Jeffrey (texte statique ou dernière phrase).
struct JeffreyBubble: View {
    var text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            JeffreyMark(size: 22).frame(width: 34, height: 34).background(Circle().fill(Theme.surfaceRaised))
            VStack(alignment: .leading, spacing: 3) {
                Text("JEFFREY").font(.system(size: 9, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
                Text(text).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
    }
}

struct PrimaryButton: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
            .font(.display(16, weight: .black)).foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(Capsule().fill(Theme.lime))
            .shadow(color: Theme.lime.opacity(0.35), radius: 14, y: 5)
        }
    }
}
