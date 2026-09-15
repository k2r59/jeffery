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
                        JeffreyBubble(text: coach.lastCoachLine ?? (coach.phase == .connecting ? "J'arrive…" : "Je t'écoute. Parle-moi quand tu veux."),
                                      label: coach.coachSpeaking ? "JEFFREY TE PARLE" : "JEFFREY")
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
            Label(coach.latest?.kind.label.uppercased() ?? "SÉANCE", systemImage: "figure.run")
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
            let elapsed = liveElapsed(s, now: context.date)
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
            tile(s?.heartRate.map { "\(Int($0))" } ?? "--", zone.map { "bpm · \($0.label)" } ?? "bpm", Theme.zoneColor(zone), icon: "heart.fill")
        }
    }

    private func tile(_ value: String, _ unit: String, _ color: Color, icon: String? = nil) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.pulse) }
                Text(value).font(.display(24, weight: .black).monospacedDigit()).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            }
            Text(unit).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity).frame(height: 74)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
    }

    private func proposalCard(_ p: GoalProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Nouvel objectif · \(p.goal.label)", systemImage: "timer").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
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
            Image(systemName: "flag.checkered").foregroundStyle(Theme.ice)
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ta musique").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Text(music.title.map { "\($0)\(music.artist.map { " · \($0)" } ?? "")" } ?? "Aucune musique sélectionnée")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 4) {
                musicButton("backward.fill") { music.previous() }
                musicButton(music.isPlaying ? "pause.fill" : "play.fill", prominent: true) {
                    if !music.authorized { music.requestAuthorization() }
                    music.togglePlayPause()
                }
                musicButton("forward.fill") { music.next() }
            }
        }
        .card()
        .onAppear { music.requestAuthorization() }
    }

    private func musicButton(_ icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: prominent ? 15 : 12, weight: .bold))
                .foregroundStyle(prominent ? Theme.background : .white)
                .frame(width: prominent ? 38 : 32, height: prominent ? 38 : 32)
                .background(Circle().fill(prominent ? Theme.lime : Theme.surfaceRaised))
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            PrimaryButton(title: "Parler à Jeffrey", icon: "mic.fill") { showTalk = true }
                .disabled(coach.phase != .live).opacity(coach.phase == .live ? 1 : 0.5)
            HStack(spacing: 10) {
                Button { coach.togglePause() } label: {
                    Label(coach.isPaused ? "Reprendre" : "Pause", systemImage: coach.isPaused ? "play.fill" : "pause.fill")
                        .font(.display(14, weight: .black)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52).background(Capsule().fill(Theme.surfaceRaised))
                }
                .disabled(coach.phase != .live)
                Button { coach.stop() } label: {
                    Label("Terminer", systemImage: "stop.fill")
                        .font(.display(14, weight: .black)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52).background(Capsule().fill(Theme.pulse.opacity(0.85)))
                }
                .disabled(coach.phase == .ending)
            }
        }
    }
}

/// 04 · Le point coach : Jeffrey écoute, la conversation défile, une proposition se confirme d'un toucher.
struct TalkSheet: View {
    @EnvironmentObject private var coach: CoachSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").font(.system(size: 16, weight: .bold)).foregroundStyle(.white) }
                    Spacer()
                    if coach.goal.kind != .free, let s = coach.latest {
                        Text(coach.goal.progress(elapsed: s.elapsed, distance: coach.displayDistance).remaining ?? "")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Color.clear.frame(width: 20)
                }
                .padding(.top, 14)
                JeffreyMark(state: coach.coachSpeaking ? .speaking : .listening, size: 96)
                    .shadow(color: Theme.lime.opacity(0.5), radius: 24)
                Text(coach.coachSpeaking ? "Jeffrey te parle" : "Jeffrey est à l'écoute")
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
                        Label("Nouvel objectif · \(p.goal.label)", systemImage: "timer")
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
                    Image(systemName: "mic.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.lime)
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
