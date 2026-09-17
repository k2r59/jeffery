import SwiftUI

struct LiveSessionView: View {
    @EnvironmentObject private var coach: CoachSession
    @StateObject private var music = MusicController()
    @State private var showTalk = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            RadialGradient(colors: [Theme.lime.opacity(0.18), .clear], center: .topLeading, startRadius: 0, endRadius: 420).ignoresSafeArea()
            VStack(spacing: 12) {
                header
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        timerCard
                        metricsRow
                        jeffreyLiveCard
                        if let p = coach.proposal { proposalCard(p) }
                        if let r = coach.reference { referenceCard(r) }
                        musicCard
                        if let err = coach.errorMessage { Text(err).font(.caption).foregroundStyle(Theme.pulse) }
                    }
                }
                controls
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showTalk) { TalkSheet().environmentObject(coach) }
        .onChange(of: coach.proposal) { _, p in if p != nil { showTalk = true } }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 6) { JIcon("course", size: 16); Text(coach.latest?.kind.label.uppercased() ?? "SÉANCE") }
                .font(.system(size: 13, weight: .heavy)).tracking(1).foregroundStyle(.white)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(coach.connectivity.isReachable ? Theme.lime : Theme.ember).frame(width: 7, height: 7)
                Text(coach.connectivity.isReachable ? "Apple Watch connectée" : "Montre non joignable")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.top, 14)
    }

    private var timerCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let s = coach.latest
            let elapsed = coach.liveElapsed(at: context.date)
            let p = coach.goal.progress(elapsed: elapsed, distance: coach.displayDistance)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Formatters.elapsed(elapsed))
                        .font(.display(76, weight: .black).monospacedDigit()).foregroundStyle(.white)
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Spacer()
                    if s?.state == .paused { Text("PAUSE").font(.display(12, weight: .black)).tracking(2).foregroundStyle(Theme.ember) }
                }
                if coach.goal.kind != .free {
                    HStack {
                        Text("Objectif · \(coach.goal.label)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        Spacer()
                        Text(coach.goalReached ? "Atteint ✓" : (p.remaining ?? "")).font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(coach.goalReached ? Theme.lime : Theme.muted)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule().fill(Theme.lime).frame(width: geo.size.width * p.fraction)
                        }
                    }
                    .frame(height: 8)
                } else {
                    Text("Sortie libre").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                }
            }
            .card()
        }
    }

    /// Jeffrey est actif dès la connexion : pas de bouton à presser, on lui parle quand on veut.
    private var jeffreyLiveCard: some View {
        Button { showTalk = true } label: {
            HStack(alignment: .top, spacing: 12) {
                JeffreyMark(state: coach.coachSpeaking ? .speaking : (coach.phase == .live ? .listening : .available), size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(coach.phase == .connecting ? "JEFFREY ARRIVE" : (coach.coachSpeaking ? "JEFFREY TE PARLE" : (coach.userSpeaking ? "JEFFREY T'ÉCOUTE" : "JEFFREY EST LÀ")))
                        .font(.system(size: 10, weight: .heavy)).tracking(1.5)
                        .foregroundStyle(coach.coachSpeaking || coach.userSpeaking ? Theme.citron : Theme.muted)
                    Text(coach.lastCoachLine ?? (coach.phase == .connecting ? "Connexion en cours…" : "Parle-lui quand tu veux, il t'entend."))
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.creme)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                JIcon("conversation", size: 16).foregroundStyle(Theme.muted)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
        }
        .buttonStyle(.plain)
    }

    private func liveElapsed(_ s: MetricsSnapshot?, now: Date) -> TimeInterval {
        guard let s else { return 0 }
        guard s.state == .running, coach.phase != .idle else { return s.elapsed }
        return s.elapsed + max(0, now.timeIntervalSince(s.timestamp))
    }

    private var metricsRow: some View {
        let s = coach.latest
        let zone = coach.currentZone
        return HStack(spacing: 10) {
            tile(coach.displayDistance.map { String(format: "%.2f", $0 / 1000).replacingOccurrences(of: ".", with: ",") } ?? "--", "km", .white)
            tile(coach.pace?.replacingOccurrences(of: " /km", with: "").replacingOccurrences(of: ":", with: "'") ?? "--", "/km", .white)
            tile(s?.heartRate.map { "\(Int($0))" } ?? "--", zone.map { "bpm · \($0.label)" } ?? "bpm", Theme.zoneColor(zone), icon: "frequence-cardiaque")
        }
    }

    private func tile(_ value: String, _ unit: String, _ color: Color, icon: String? = nil) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                if let icon { JIcon(icon, size: 16).foregroundStyle(Theme.pulse) }
                Text(value).font(.display(24, weight: .black).monospacedDigit()).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            }
            Text(unit).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity).frame(height: 74)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
    }

    private func proposalCard(_ p: GoalProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) { JIcon("objectif", size: 16); Text("Nouvel objectif · \(p.goal.label)") }.font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            if !p.reason.isEmpty { Text(p.reason).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted) }
            HStack(spacing: 10) {
                Button { coach.resolveProposal(accept: true) } label: {
                    Text("Confirmer").font(.display(14, weight: .black)).foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity).frame(height: 44).background(Capsule().fill(Theme.lime))
                }
                Button { coach.resolveProposal(accept: false) } label: {
                    Text("Garder \(coach.goal.label)").font(.display(14, weight: .black)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 44).background(Capsule().fill(Theme.surfaceRaised))
                }
            }
        }
        .card()
    }

    private func referenceCard(_ r: ReferenceStatus) -> some View {
        HStack {
            JIcon("refaire-parcours", size: 16).foregroundStyle(Theme.citron)
            Text(r.offRoute ? "Hors tracé" : "\(r.progressText) · 500 m : \(r.reliefText)")
            Spacer()
            if let g = r.ghostText, !r.offRoute {
                Text(g).font(.system(size: 12, weight: .black)).foregroundStyle((r.ghostDelta ?? 0) >= 0 ? Theme.lime : Theme.ember)
            }
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.muted)
        .card()
    }

    private var musicCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ta musique").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    Text(musicSubtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if music.title != nil || music.isPlaying {
                    HStack(spacing: 4) {
                        musicButton("piste-precedente") { music.previous() }
                        musicButton(music.isPlaying ? "pause" : "lecture", prominent: true) {
                            if !music.authorized { music.requestAuthorization() }
                            music.togglePlayPause()
                        }
                        musicButton("piste-suivante") { music.next() }
                    }
                }
            }
            if music.title == nil, !music.suggestedApps.isEmpty {
                // Lecteurs tiers : iOS ne laisse pas afficher leur titre, on ouvre l'app (le dernier lancé en premier).
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(music.suggestedApps) { app in
                            Button { music.open(app) } label: {
                                HStack(spacing: 6) {
                                    JIcon("musique", size: 14)
                                    Text(app.name)
                                }
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(music.lastApp == app.id ? Theme.background : Theme.creme)
                                .padding(.horizontal, 12).frame(height: 34)
                                .background(Capsule().fill(music.lastApp == app.id ? Theme.citron : Theme.surfaceRaised))
                            }
                        }
                        Button {
                            if !music.authorized { music.requestAuthorization() }
                            music.togglePlayPause()
                        } label: {
                            HStack(spacing: 6) { JIcon("lecture", size: 14); Text("Apple Music") }
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.creme)
                                .padding(.horizontal, 12).frame(height: 34)
                                .background(Capsule().fill(Theme.surfaceRaised))
                        }
                    }
                }
            }
        }
        .card()
        .onAppear { music.requestAuthorization() }
    }

    private var musicSubtitle: String {
        if let t = music.title { return "\(t)\(music.artist.map { " · \($0)" } ?? "")" }
        if music.otherAudioPlaying {
            let name = music.suggestedApps.first(where: { $0.id == music.lastApp })?.name ?? "une autre app"
            return "En lecture dans \(name) · atténuée quand Jeffrey parle"
        }
        return "Rien en lecture · lance un lecteur"
    }

    private func musicButton(_ icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            JIcon(icon, size: prominent ? 16 : 13)
                .foregroundStyle(prominent ? Theme.background : .white)
                .frame(width: prominent ? 38 : 32, height: prominent ? 38 : 32)
                .background(Circle().fill(prominent ? Theme.lime : Theme.surfaceRaised))
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { coach.togglePause() } label: {
                    HStack(spacing: 6) { JIcon(coach.isPaused ? "lecture" : "pause", size: 16); Text(coach.isPaused ? "Reprendre" : "Pause") }
                        .font(.display(14, weight: .black)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52).background(Capsule().fill(Theme.surfaceRaised))
                }
                .disabled(coach.phase != .live)
                Button { coach.stop() } label: {
                    HStack(spacing: 6) { JIcon("arreter", size: 16); Text("Terminer") }
                        .font(.display(14, weight: .black)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52).background(Capsule().fill(Theme.pulse.opacity(0.85)))
                }
                .disabled(coach.phase == .ending)
            }
        }
    }
}

/// La conversation en cours : Jeffrey écoute en permanence, ceci n'est qu'une fenêtre de lecture (et de confirmation d'objectif).
struct TalkSheet: View {
    @EnvironmentObject private var coach: CoachSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Button { dismiss() } label: { JIcon("retour", size: 18).foregroundStyle(Theme.creme) }
                    Spacer()
                    if coach.goal.kind != .free {
                        Text(coach.goal.progress(elapsed: coach.liveElapsed(), distance: coach.displayDistance).remaining ?? "")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Color.clear.frame(width: 20)
                }
                .padding(.top, 14)
                JeffreyMark(state: coach.coachSpeaking ? .speaking : .listening, size: 96)
                    .shadow(color: Theme.lime.opacity(0.5), radius: 24)
                Text(coach.coachSpeaking ? "Jeffrey te parle" : (coach.userSpeaking ? "Jeffrey t'écoute" : "Jeffrey est là, parle-lui"))
                    .font(.display(18, weight: .black)).foregroundStyle(.white)
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 8) {
                            ForEach(coach.transcript.suffix(12)) { line in
                                bubble(line).id(line.id)
                            }
                        }
                    }
                    .onChange(of: coach.transcript) { _, lines in
                        if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                if let p = coach.proposal {
                    VStack(spacing: 10) {
                        HStack(spacing: 6) { JIcon("objectif", size: 16); Text("Nouvel objectif · \(p.goal.label)") }
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
                        HStack(spacing: 10) {
                            Button { coach.resolveProposal(accept: true) } label: {
                                Text("Confirmer").font(.display(15, weight: .black)).foregroundStyle(Theme.background)
                                    .frame(maxWidth: .infinity).frame(height: 50).background(Capsule().fill(Theme.lime))
                            }
                            Button { coach.resolveProposal(accept: false) } label: {
                                Text("Garder \(coach.goal.label)").font(.display(15, weight: .black)).foregroundStyle(.white)
                                    .frame(maxWidth: .infinity).frame(height: 50).background(Capsule().fill(Theme.surfaceRaised))
                            }
                        }
                    }
                }
                VStack(spacing: 6) {
                    JIcon("micro", size: 14).foregroundStyle(Theme.citron)
                        .frame(width: 60, height: 60).background(Circle().stroke(Theme.lime, lineWidth: 2))
                    Text(coach.userSpeaking ? "Je t'entends…" : "Micro activé").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 20)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func bubble(_ line: TranscriptLine) -> some View {
        switch line.role {
        case .info:
            Text(line.text).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: .infinity)
        case .coach:
            HStack(alignment: .top, spacing: 8) {
                JeffreyMark(size: 22)
                Text(line.text).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
                Spacer(minLength: 24)
            }
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(line.text).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.background)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.lime.opacity(0.85)))
            }
        }
    }
}
