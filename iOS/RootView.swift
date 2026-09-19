import SwiftUI

struct RootView: View {
    @EnvironmentObject private var coach: CoachSession
    @AppStorage(Prefs.onboarded) private var onboarded: Bool = false
    @StateObject private var history = WorkoutHistory()
    @State private var tab = 0
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
        .fullScreenCover(isPresented: Binding(get: { coach.phase != .idle }, set: { _ in })) {
            LiveSessionView().environmentObject(coach)
        }
        .sheet(item: $coach.endedSummary) { summary in SessionEndView(summary: summary) }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { _ in })) { OnboardingView() }
        .task { await history.load() }
        .onChange(of: coach.phase) { _, phase in
            if phase == .idle { Task { await history.load() } }
        }
        .onChange(of: scenePhase) { _, p in
            if p == .active { coach.resumeIfWaitingForForeground() }
        }
        .onAppear {
            #if DEBUG
            if let t = ProcessInfo.processInfo.environment["WATCHCOACH_TAB"], let i = Int(t) { tab = i }
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
    var trailing: AnyView? = nil
    var body: some View {
        HStack(alignment: .top) {
            JeffreyWordmark(size: 26, signature: true)
            Spacer()
            if let trailing { trailing }
        }
    }
}

/// Bulle de Jeffrey (texte statique ou dernière phrase).
struct JeffreyBubble: View {
    var text: String
    var label: String = "JEFFREY"
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            JeffreyMark(size: 22).frame(width: 34, height: 34).background(Circle().fill(Theme.surfaceRaised))
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 9, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
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
    var icon: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { JIcon(icon, size: 18) }
                Text(title)
            }
            .font(.display(16, weight: .black)).foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(Capsule().fill(Theme.lime))
            .shadow(color: Theme.lime.opacity(0.35), radius: 14, y: 5)
        }
    }
}
