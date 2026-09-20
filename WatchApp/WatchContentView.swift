import SwiftUI
import WatchKit

/// La montre est le miroir et la télécommande de l'iPhone : un bouton pour démarrer, l'état de Jeffrey, Pause et Terminer.
struct WatchContentView: View {
    @EnvironmentObject private var workout: WorkoutManager
    @ObservedObject private var mirror = WatchMirror.shared
    @State private var page = 1
    @State private var sending = false
    @State private var sceneReturnTask: Task<Void, Never>?
    /// Identifiant du chrono pour lequel le décompte final a déjà repris l'écran.
    @State private var finalCountdownShownFor: String?

    private let citron = JeffreyPalette.citron
    private let creme = JeffreyPalette.creme
    private let sauge = JeffreyPalette.sauge
    private let surface = JeffreyPalette.surface

    private var live: Bool { mirror.state.phase != "idle" || workout.isActive }

    private var scene: WatchScene? { mirror.state.scene }
    private var hasTimer: Bool { mirror.state.timerEndsAt != nil || scene?.kind == .countdown || scene?.kind == .interval }

    /// Bilan affiché après la séance jusqu'à « Voir sur iPhone ».
    @State private var summary: CoachMirror?
    @State private var summaryEnergy: Double?

    // Pages : 0 contrôles (ou pause) · 1 séance · 2 effort · 3 intervalles (si chrono) · 4 Jeffrey
    var body: some View {
        if live {
            TabView(selection: $page) {
                controlsOrPausePage.tag(0)
                sessionPage.tag(1)
                effortPage.tag(2)
                if hasTimer { intervalPage.tag(3) }
                coachPage.tag(4)
            }
            .tabViewStyle(.page)
            .onAppear {
                page = 1
                if let scene { react(to: scene) }
                #if DEBUG
                if let p = ProcessInfo.processInfo.environment["WATCHCOACH_PAGE"], let i = Int(p) { page = i }
                #endif
            }
            // Jeffrey choisit la page : un chrono qui démarre, une cible, un message prennent la main quelques secondes.
            .onChange(of: scene?.id) { _, _ in
                if let scene { react(to: scene) } else { sceneReturnTask?.cancel(); if page == 3 { withAnimation { page = 1 } } }
            }
            .onChange(of: mirror.state.paused) { _, paused in
                if paused { withAnimation { page = 0 } } else if page == 0 { withAnimation { page = 1 } }
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
                // Dernières secondes d'un bloc : le décompte revient pour le 3-2-1, une fois par bloc.
                guard let scene, scene.kind == .countdown || scene.kind == .interval, let end = scene.endsAt,
                      page != 3, finalCountdownShownFor != scene.id else { return }
                let left = end.timeIntervalSince(now)
                if left > 0, left <= 10 { finalCountdownShownFor = scene.id; withAnimation { page = 3 } }
            }
            .onChange(of: mirror.state) { _, m in
                SceneHaptics.shared.observe(m.scene, heartRate: workout.snapshot.heartRate ?? m.heartRate)
                if m.phase != "idle", m.elapsed > 30 { summary = m; summaryEnergy = workout.snapshot.activeEnergy ?? m.energy }
            }
        } else if let done = summary {
            WatchSummaryPage(elapsed: done.elapsed, distance: workout.snapshot.distance ?? done.distance,
                             averageHeartRate: done.averageHeartRate, usesDistance: done.kind.usesDistance,
                             energy: summaryEnergy, onDismiss: { summary = nil })
        } else {
            startPage
        }
    }

    /// Réaction à une scène : chrono → page Intervalles 8 s puis retour ; cible zone/allure → page Effort 8 s ;
    /// message de Jeffrey → page Jeffrey le temps du message ; montée, fantôme, fête → bandeau sur la page Séance.
    private func react(to scene: WatchScene) {
        sceneReturnTask?.cancel()
        let target: Int
        switch scene.kind {
        case .countdown, .interval: target = 3
        case .zone, .pace: target = 2
        case .message: target = 4
        case .celebration, .climb, .ghost: target = 1
        }
        withAnimation { page = target }
        guard target != 1, scene.kind != .message else { return }
        let id = scene.id
        sceneReturnTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, self.scene?.id == id, page == target else { return }
            withAnimation { page = 1 }
        }
    }

    /// Ligne d'information sur la page Séance quand une scène ne mérite pas une page à elle.
    private var banner: String? {
        guard let scene else { return nil }
        switch scene.kind {
        case .celebration: return [scene.title, scene.subtitle].compactMap { $0 }.joined(separator: " · ")
        case .climb, .ghost: return [scene.title, scene.subtitle].compactMap { $0 }.joined(separator: " · ")
        default: return nil
        }
    }

    // MARK: Pages de séance

    private var sessionPage: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            WatchSessionPage(mirror: mirror.state, snapshot: workout.snapshot, elapsed: liveElapsed(mirror.state, at: ctx.date), banner: banner)
        }
    }

    private var effortPage: some View {
        WatchEffortPage(mirror: mirror.state, snapshot: workout.snapshot)
    }

    private var intervalPage: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            WatchIntervalPage(mirror: mirror.state, now: ctx.date)
                .onChange(of: ctx.date) { _, now in
                    SceneHaptics.shared.observe(scene, heartRate: workout.snapshot.heartRate ?? mirror.state.heartRate, now: now)
                }
        }
    }

    private var coachPage: some View {
        WatchCoachPage(mirror: mirror.state, phoneReachable: mirror.phoneReachable) { question in
            WatchSender.shared.request(.ask, kind: mirror.state.kind, text: question) { refusal in
                mirror.notice = refusal
                WKInterfaceDevice.current().play(refusal == nil ? .click : .failure)
            }
        }
    }

    @ViewBuilder private var controlsOrPausePage: some View {
        let m = mirror.state
        if m.paused {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                WatchPausePage(elapsed: liveElapsed(m, at: ctx.date),
                               onResume: { WatchSender.shared.request(.requestResume, kind: m.kind) { _ in withAnimation { page = 1 } } },
                               onEnd: endSession)
            }
        } else {
            WatchControlsPage(phoneReachable: mirror.phoneReachable,
                              onPause: { WatchSender.shared.request(.requestPause, kind: m.kind) { _ in } },
                              onEnd: endSession)
        }
    }

    private func endSession() {
        let m = mirror.state
        WatchSender.shared.request(.requestEnd, kind: m.kind) { refusal in
            // iPhone injoignable, ou déjà à l'arrêt : on termine la capture ici.
            if refusal != nil || m.phase == "idle" { workout.end() }
        }
    }

    // MARK: Démarrage

    private var startPage: some View {
        ScrollView {
            VStack(spacing: 10) {
                JeffreyWordmark(size: 15).padding(.top, 2)
                Picker("Sport", selection: $workout.selectedKind) {
                    ForEach(WorkoutKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.navigationLink)
                .tint(citron)
                Button {
                    guard !sending else { return }
                    sending = true
                    WatchSender.shared.request(.requestStart, kind: workout.selectedKind) { refusal in
                        sending = false
                        mirror.notice = refusal
                    }
                } label: {
                    HStack(spacing: 6) {
                        JeffreyMark(size: 18)
                        Text(sending ? "Lancement…" : "Démarrer avec Jeffrey").font(.system(size: 14, weight: .black))
                    }
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity).frame(height: 44)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(citron))
                .disabled(sending)
                HStack(spacing: 5) {
                    Circle().fill(mirror.phoneReachable ? citron : sauge).frame(width: 6, height: 6)
                    Text(mirror.phoneReachable ? "iPhone connecté" : "iPhone hors de portée").font(.system(size: 11, weight: .semibold)).foregroundStyle(sauge)
                }
                Text("ping \(mirror.lastPing)\(workout.standbyActive ? " · veille active" : "")").font(.system(size: 9, weight: .medium)).foregroundStyle(sauge.opacity(0.7))
                if let n = mirror.notice ?? (workout.statusMessage.isEmpty ? nil : workout.statusMessage) {
                    Text(n).font(.system(size: 10, weight: .medium)).foregroundStyle(sauge).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// Plus de nouvelles de l'iPhone depuis 2 min alors qu'il était en séance : l'app s'est arrêtée ou il est hors de portée.
    private func phoneLost(_ m: CoachMirror, at now: Date = Date()) -> Bool {
        m.phase != "idle" && now.timeIntervalSince(m.timestamp) > 120
    }

    private func liveElapsed(_ m: CoachMirror, at now: Date = Date()) -> TimeInterval {
        // Chrono figé sur la dernière nouvelle : on n'extrapole pas un iPhone qui ne répond plus.
        if m.phase == "live", !m.paused, !phoneLost(m, at: now) { return m.elapsed + max(0, now.timeIntervalSince(m.timestamp)) }
        if m.phase != "idle" { return m.elapsed }
        return workout.snapshot.elapsed
    }

}
