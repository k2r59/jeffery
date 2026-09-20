import SwiftUI

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

    var body: some View {
        if live {
            TabView(selection: $page) {
                controlsPage.tag(0)
                livePage.tag(1)
                statsPage.tag(2)
                if let scene { scenePage(scene).tag(3) }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // En séance, tout l'écran pour Jeffrey : ni l'heure système ni les points de pagination.
            .persistentSystemOverlays(.hidden)
            .onAppear {
                if let scene { showScene(scene) } else { page = 1 }
                #if DEBUG
                if let p = ProcessInfo.processInfo.environment["WATCHCOACH_PAGE"], let i = Int(p) { page = i }
                #endif
            }
            // Jeffrey choisit l'écran : une scène qui apparaît prend la main, sa disparition ramène au direct.
            .onChange(of: scene?.id) { _, _ in
                if let scene { showScene(scene) } else { sceneReturnTask?.cancel(); withAnimation { page = 1 } }
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
                // Dernières secondes d'un chrono : le décompte revient pour le 3-2-1, une fois par bloc.
                guard let scene, scene.kind == .countdown || scene.kind == .interval, let end = scene.endsAt,
                      page != 3, finalCountdownShownFor != scene.id else { return }
                let left = end.timeIntervalSince(now)
                if left > 0, left <= 10 { finalCountdownShownFor = scene.id; withAnimation { page = 3 } }
            }
            .onChange(of: mirror.state) { _, m in
                SceneHaptics.shared.observe(m.scene, heartRate: workout.snapshot.heartRate ?? m.heartRate)
            }
        } else {
            startPage
        }
    }

    /// Une scène prend l'écran. Un chrono ne le garde pas : un coup d'œil à son lancement, puis retour au direct
    /// (FC, distance, allure, avec le chrono en carte), sinon on est coupé des mesures pendant tout un programme.
    private func showScene(_ scene: WatchScene) {
        sceneReturnTask?.cancel()
        withAnimation { page = 3 }
        guard scene.kind == .countdown || scene.kind == .interval else { return }
        let id = scene.id
        sceneReturnTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, self.scene?.id == id, page == 3 else { return }
            withAnimation { page = 1 }
        }
    }

    // MARK: Stats (zones, kcal, FC, vitesse moyenne)

    private var statsPage: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            WatchStatsView(mirror: mirror.state, snapshot: workout.snapshot, elapsed: liveElapsed(mirror.state, at: ctx.date))
        }
    }

    // MARK: Scène pilotée par Jeffrey

    private func scenePage(_ scene: WatchScene) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            WatchSceneView(scene: scene, heartRate: workout.snapshot.heartRate ?? mirror.state.heartRate, elapsed: liveElapsed(mirror.state, at: ctx.date))
                .onChange(of: ctx.date) { _, now in
                    SceneHaptics.shared.observe(scene, heartRate: workout.snapshot.heartRate ?? mirror.state.heartRate, now: now)
                }
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

    // MARK: Séance en direct (miroir de l'iPhone)

    private var livePage: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in livePageContent }
    }

    private var livePageContent: some View {
        let m = mirror.state
        let s = workout.snapshot
        let hr = s.heartRate ?? m.heartRate
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // En-tête sur la ligne de l'heure système (place réservée à droite pour l'heure).
                HStack(spacing: 6) {
                    JeffreyVoiceView(speaking: m.coachSpeaking, size: 20)
                    Text(stateLabel(m)).font(.system(size: 12, weight: .heavy)).foregroundStyle(m.coachSpeaking || m.userSpeaking ? citron : sauge).lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(height: 24).padding(.trailing, 62).padding(.top, 10)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Formatters.elapsed(liveElapsed(m, at: context.date)))
                        .font(.system(size: 40, weight: .black, design: .default).monospacedDigit())
                        .foregroundStyle(m.paused ? sauge : creme)
                }
                if let g = m.goalLabel {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Objectif · \(g)").font(.system(size: 12, weight: .bold)).foregroundStyle(creme)
                            Spacer()
                            Text(m.goalReached ? "Atteint ✓" : (m.remaining ?? "")).font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(m.goalReached ? citron : sauge)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(creme.opacity(0.12))
                                Capsule().fill(citron).frame(width: geo.size.width * min(1, m.progress))
                            }
                        }
                        .frame(height: 5)
                    }
                }
                HStack(spacing: 10) {
                    metric("frequence-cardiaque", hr.map { "\(Int($0))" } ?? "--", "bpm")
                    if m.kind.usesDistance {
                        metric("distance", (s.distance ?? m.distance).map { String(format: "%.2f", $0 / 1000) } ?? "--", "km")
                    }
                    if let e = s.activeEnergy { metric("energie", "\(Int(e))", "kcal") }
                }
                if let tl = m.timerLabel, let te = m.timerEndsAt {
                    HStack {
                        Text(tl.capitalized).font(.system(size: 13, weight: .bold)).foregroundStyle(creme).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer()
                        Text(Formatters.elapsed(max(0, te.timeIntervalSinceNow))).font(.system(size: 22, weight: .black, design: .default).monospacedDigit()).foregroundStyle(citron)
                    }
                    .padding(8).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(citron.opacity(0.15)))
                }
                if m.phase == "foreground" {
                    Text("Ouvre Jeffrey sur l'iPhone pour lancer la voix").font(.system(size: 12, weight: .bold)).foregroundStyle(citron)
                } else if let line = m.lastLine {
                    Text(line).font(.system(size: 13, weight: .medium)).foregroundStyle(creme).lineLimit(4)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(surface))
                }
                if workout.needsBackgroundExtension {
                    Button("Prolonger l'arrière-plan") { workout.extendBackground() }.tint(citron).font(.system(size: 11, weight: .bold))
                }
                Text("← pause et fin · stats →").font(.system(size: 10)).foregroundStyle(sauge.opacity(0.7)).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .ignoresSafeArea(edges: .top)
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

    private func stateLabel(_ m: CoachMirror) -> String {
        if phoneLost(m) { return mirror.phoneReachable ? "JEFFREY NE RÉPOND PLUS" : "IPHONE PERDU" }
        switch m.phase {
        case "connecting": return "JEFFREY ARRIVE"
        case "foreground": return "EN ATTENTE DE L'IPHONE"
        case "ending": return "DÉBRIEF"
        case "live": return m.coachSpeaking ? "JEFFREY TE PARLE" : (m.userSpeaking ? "JEFFREY T'ÉCOUTE" : "JEFFREY EST LÀ")
        default: return workout.isActive ? "CAPTURE EN COURS" : "PRÊT"
        }
    }

    private func metric(_ icon: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            JIcon(icon, size: 12).foregroundStyle(sauge)
            Text(value).font(.system(size: 24, weight: .black, design: .default).monospacedDigit()).foregroundStyle(creme)
            Text(unit).font(.system(size: 11, weight: .bold)).foregroundStyle(sauge)
        }
    }

    // MARK: Télécommande

    private var controlsPage: some View {
        let m = mirror.state
        return VStack(spacing: 12) {
            HStack(spacing: 18) {
                controlButton("arreter", "Terminer", JeffreyPalette.alerte) {
                    WatchSender.shared.request(.requestEnd, kind: m.kind) { refusal in
                        // iPhone injoignable, ou déjà à l'arrêt : on termine la capture ici.
                        if refusal != nil || m.phase == "idle" { workout.end() }
                    }
                }
                if m.paused {
                    controlButton("lecture", "Reprendre", citron) {
                        WatchSender.shared.request(.requestResume, kind: m.kind) { _ in page = 1 }
                    }
                } else {
                    controlButton("pause", "Pause", creme) {
                        WatchSender.shared.request(.requestPause, kind: m.kind) { _ in }
                    }
                }
            }
            Text(mirror.phoneReachable ? "Commandes envoyées à l'iPhone" : "iPhone hors de portée")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(sauge).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func controlButton(_ icon: String, _ title: String, _ color: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                JIcon(icon, size: 24).frame(width: 60, height: 60)
            }
            .buttonStyle(.plain)
            .foregroundStyle(color)
            .background(Circle().fill(color.opacity(0.22)))
            .clipShape(Circle())
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(creme)
        }
    }
}
