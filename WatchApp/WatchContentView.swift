import SwiftUI

/// La montre est le miroir et la télécommande de l'iPhone : un bouton pour démarrer, l'état de Jeffrey, Pause et Terminer.
struct WatchContentView: View {
    @EnvironmentObject private var workout: WorkoutManager
    @ObservedObject private var mirror = WatchMirror.shared
    @State private var page = 1
    @State private var sending = false

    private let citron = JeffreyPalette.citron
    private let creme = JeffreyPalette.creme
    private let sauge = JeffreyPalette.sauge
    private let surface = JeffreyPalette.surface

    private var live: Bool { mirror.state.phase != "idle" || workout.isActive }

    var body: some View {
        if live {
            TabView(selection: $page) {
                controlsPage.tag(0)
                livePage.tag(1)
            }
            .tabViewStyle(.page)
            .onAppear { page = 1 }
        } else {
            startPage
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
                    WatchSender.shared.request(.requestStart, kind: workout.selectedKind) { ok in
                        sending = false
                        mirror.notice = ok ? nil : "iPhone injoignable : ouvre Jeffrey sur l'iPhone"
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    JeffreyMark(state: m.coachSpeaking ? .speaking : (m.phase == "live" ? .listening : .available), size: 20)
                    Text(stateLabel(m)).font(.system(size: 10, weight: .heavy)).foregroundStyle(m.coachSpeaking || m.userSpeaking ? citron : sauge)
                    Spacer()
                    Text(m.kind.label.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(sauge)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Formatters.elapsed(liveElapsed(m, at: context.date)))
                        .font(.system(size: 34, weight: .black, design: .default).monospacedDigit())
                        .foregroundStyle(m.paused ? sauge : creme)
                }
                if let g = m.goalLabel {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Objectif · \(g)").font(.system(size: 10, weight: .bold)).foregroundStyle(creme)
                            Spacer()
                            Text(m.goalReached ? "Atteint ✓" : (m.remaining ?? "")).font(.system(size: 10, weight: .semibold).monospacedDigit())
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
                        Text(tl.capitalized).font(.system(size: 11, weight: .bold)).foregroundStyle(creme)
                        Spacer()
                        Text(Formatters.elapsed(max(0, te.timeIntervalSinceNow))).font(.system(size: 20, weight: .black, design: .default).monospacedDigit()).foregroundStyle(citron)
                    }
                    .padding(8).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(citron.opacity(0.15)))
                }
                if m.phase == "foreground" {
                    Text("Ouvre Jeffrey sur l'iPhone pour lancer la voix").font(.system(size: 10, weight: .bold)).foregroundStyle(citron)
                } else if let line = m.lastLine {
                    Text(line).font(.system(size: 11, weight: .medium)).foregroundStyle(creme).lineLimit(3)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(surface))
                }
                if workout.needsBackgroundExtension {
                    Button("Prolonger l'arrière-plan") { workout.extendBackground() }.tint(citron).font(.system(size: 11, weight: .bold))
                }
                Text("← pause et fin").font(.system(size: 9)).foregroundStyle(sauge.opacity(0.7))
            }
            .padding(.horizontal, 4)
        }
    }

    private func liveElapsed(_ m: CoachMirror, at now: Date = Date()) -> TimeInterval {
        if m.phase == "live", !m.paused { return m.elapsed + max(0, now.timeIntervalSince(m.timestamp)) }
        if m.phase != "idle" { return m.elapsed }
        return workout.snapshot.elapsed
    }

    private func stateLabel(_ m: CoachMirror) -> String {
        if !mirror.phoneReachable, Date().timeIntervalSince(m.timestamp) > 120, m.phase != "idle" { return "IPHONE PERDU" }
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
            JIcon(icon, size: 11).foregroundStyle(sauge)
            Text(value).font(.system(size: 17, weight: .black, design: .default).monospacedDigit()).foregroundStyle(creme)
            Text(unit).font(.system(size: 9, weight: .bold)).foregroundStyle(sauge)
        }
    }

    // MARK: Télécommande

    private var controlsPage: some View {
        let m = mirror.state
        return VStack(spacing: 12) {
            HStack(spacing: 18) {
                controlButton("arreter", "Terminer", JeffreyPalette.alerte) {
                    WatchSender.shared.request(.requestEnd, kind: m.kind) { ok in
                        // iPhone injoignable, ou déjà à l'arrêt : on termine la capture ici.
                        if !ok || m.phase == "idle" { workout.end() }
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
                .font(.system(size: 10, weight: .medium)).foregroundStyle(sauge)
        }
        .padding(.horizontal, 6)
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
