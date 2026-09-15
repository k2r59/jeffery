import SwiftUI

struct RootView: View {
    @EnvironmentObject private var coach: CoachSession
    @AppStorage(Prefs.onboarded) private var onboarded: Bool = false
    @StateObject private var history = WorkoutHistory()
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            TodayView(history: history, goToSessions: { tab = 1 })
                .tabItem { Label("Aujourd'hui", systemImage: "house.fill") }.tag(0)
            SessionsView(history: history)
                .tabItem { Label("Séances", systemImage: "square.stack.fill") }.tag(1)
            JeffreyView()
                .tabItem { Label("Jeffrey", systemImage: "waveform") }.tag(2)
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
        .onAppear {
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
            VStack(alignment: .leading, spacing: 2) {
                JeffreyWordmark(size: 24)
                Text("À tes côtés. À ton rythme.").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            }
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
            JeffreyMark(size: 26).frame(width: 34, height: 34).background(Circle().fill(Theme.surfaceRaised))
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
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.display(16, weight: .black)).foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(Capsule().fill(Theme.lime))
            .shadow(color: Theme.lime.opacity(0.35), radius: 14, y: 5)
        }
    }
}

struct KindChips: View {
    @Binding var kindRaw: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(WorkoutKind.allCases) { k in
                    let selected = k.rawValue == kindRaw
                    Button { withAnimation(.snappy) { kindRaw = k.rawValue } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: icon(k)).font(.system(size: 15, weight: .bold))
                            Text(k.label).font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(selected ? Theme.background : .white)
                        .frame(width: 72, height: 56)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? Theme.lime : Theme.surface))
                    }
                }
            }
        }
    }
    private func icon(_ k: WorkoutKind) -> String {
        switch k {
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .cycling: return "figure.outdoor.cycle"
        case .hiking: return "figure.hiking"
        case .functionalStrength: return "dumbbell.fill"
        case .hiit: return "bolt.heart.fill"
        case .other: return "figure.mixed.cardio"
        }
    }
}
