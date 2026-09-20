import SwiftUI

/// Vue de séance sur l'iPhone, d'après la maquette « Course » (kit graphique du 19/09/2026) : chrono en tête, mesures,
/// programme en cours, Jeffrey, musique, puis Pause (action principale) et Terminer.
struct LiveSessionView: View {
    @EnvironmentObject private var coach: CoachSession
    @StateObject private var music = MusicController()
    @State private var showTalk = false
    @State private var showActivityDetail = false
    @State private var showMusicApps = false

    // Tokens de la maquette (styles/tokens.json)
    private let bg = Color(red: 0x0C / 255, green: 0x12 / 255, blue: 0x0F / 255)
    private let surface = Color(red: 0x16 / 255, green: 0x1D / 255, blue: 0x17 / 255)
    private let surfaceActive = Color(red: 0x25 / 255, green: 0x2F / 255, blue: 0x17 / 255)
    private let accent = Color(red: 0xCF / 255, green: 0xFF / 255, blue: 0x58 / 255)
    private let text = Color(red: 0xF6 / 255, green: 0xF8 / 255, blue: 0xF3 / 255)
    private let muted = Color(red: 0xA4 / 255, green: 0xAF / 255, blue: 0x9A / 255)
    private let border = Color(red: 0x30 / 255, green: 0x39 / 255, blue: 0x2E / 255)
    private let danger = Color(red: 0xEF / 255, green: 0x70 / 255, blue: 0x6A / 255)
    private let radius: CGFloat = 20

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            // Lumière verte discrète en haut à gauche (backgrounds/course-background.svg).
            RadialGradient(colors: [Color(red: 0x33 / 255, green: 0x47 / 255, blue: 0x19 / 255).opacity(0.65), .clear],
                           center: .init(x: 0.12, y: 0.02), startRadius: 0, endRadius: 560)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                header
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        timerCard
                        metricsCard
                        if let label = coach.timerLabel, let end = coach.timerEndsAt { programCard(label, end) }
                        jeffreyCard
                        if let r = coach.reference { referenceCard(r) }
                        musicCard
                        if let err = coach.errorMessage {
                            Text(err).font(.system(size: 13, weight: .medium)).foregroundStyle(danger).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.bottom, 4)
                }
                controls
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showTalk) { TalkSheet().environmentObject(coach) }
    }

    // MARK: En-tête

    private var kind: WorkoutKind { coach.latest?.kind ?? (WorkoutKind(rawValue: UserDefaults.standard.string(forKey: Prefs.kind) ?? "") ?? .running) }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                JIcon(kind.iconName, size: 20).foregroundStyle(accent)
                Text(kind.label.uppercased()).font(.system(size: 15, weight: .heavy)).tracking(1.5).foregroundStyle(text)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(coach.connectivity.watchConnected ? accent : danger).frame(width: 8, height: 8)
                Text(coach.connectivity.linkLabel)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(muted)
            }
        }
        .padding(.top, 10)
    }

    // MARK: Chrono

    private var timeCaption: String {
        switch kind {
        case .running: return "TEMPS DE COURSE"
        case .walking, .hiking: return "TEMPS DE MARCHE"
        case .cycling: return "TEMPS DE VÉLO"
        default: return "TEMPS DE SÉANCE"
        }
    }

    private var timerCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = coach.liveElapsed(at: context.date)
            let p = coach.goal.progress(elapsed: elapsed, distance: coach.displayDistance)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    caption(timeCaption)
                    Spacer()
                    if coach.isPaused { Text("PAUSE").font(.system(size: 12, weight: .heavy)).tracking(2).foregroundStyle(danger) }
                }
                Text(Formatters.elapsed(elapsed))
                    .font(.system(size: 88, weight: .heavy).monospacedDigit()).tracking(-4)
                    .foregroundStyle(text).lineLimit(1).minimumScaleFactor(0.5)
                    .padding(.vertical, -6)
                if coach.goal.kind != .free {
                    HStack(alignment: .firstTextBaseline) {
                        HStack(spacing: 6) {
                            Text("Objectif").font(.system(size: 17, weight: .medium)).foregroundStyle(text)
                            Text(coach.goal.label).font(.system(size: 17, weight: .bold)).foregroundStyle(text)
                        }
                        Spacer()
                        Text(coach.goalReached ? "Atteint ✓" : (p.remaining ?? "")).font(.system(size: 15, weight: .medium).monospacedDigit())
                            .foregroundStyle(coach.goalReached ? accent : muted)
                    }
                    .padding(.top, 2)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(border)
                            Capsule().fill(accent).frame(width: max(8, geo.size.width * p.fraction))
                        }
                    }
                    .frame(height: 8)
                } else {
                    Text("Sortie libre").font(.system(size: 15, weight: .medium)).foregroundStyle(muted)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardShape(surface))
        }
    }

    // MARK: Mesures

    private var metricsCard: some View {
        let s = coach.latest
        let zone = coach.currentZone
        let a = coach.activity
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                metric("distance", coach.displayDistance.map { String(format: "%.2f", $0 / 1000).replacingOccurrences(of: ".", with: ",") } ?? "--", "km")
                divider
                metric("allure", coach.pace?.replacingOccurrences(of: " /km", with: "").replacingOccurrences(of: ":", with: "'") .appending("”") ?? "--", "/km")
                divider
                metric("frequence-cardiaque", s?.heartRate.map { "\(Int($0))" } ?? "--", zone.map { "bpm · \($0.label)" } ?? "bpm", iconColor: danger)
            }
            .padding(.vertical, 14)
            Rectangle().fill(border).frame(height: 1).padding(.horizontal, 16)
            Button { withAnimation(.snappy) { showActivityDetail.toggle() } } label: {
                HStack(spacing: 10) {
                    JIcon("randonnee", size: 18).foregroundStyle(muted)
                    caption(terrainCaption(a))
                    Spacer()
                    Text("D+ \(Int(a.ascent)) m").font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(text)
                    JIcon("suivant", size: 14).foregroundStyle(muted).rotationEffect(.degrees(showActivityDetail ? 90 : 0))
                }
                .padding(.horizontal, 16).frame(height: 48)
            }
            .buttonStyle(.plain)
            if showActivityDetail {
                HStack(spacing: 14) {
                    if a.activity != .unknown {
                        HStack(spacing: 6) {
                            JIcon(a.activity == .running ? "course" : (a.activity == .walking ? "marche" : (a.activity == .cycling ? "velo" : "pause")), size: 14)
                            Text(a.activity.label.capitalized)
                            if let c = a.cadence, c > 0 { Text("· \(Int(c)) pas/min").foregroundStyle(muted) }
                        }
                    }
                    Spacer()
                    Text("D− \(Int(a.descent)) m").foregroundStyle(muted)
                }
                .font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(text)
                .padding(.horizontal, 16).padding(.bottom, 14)
            }
        }
        .background(cardShape(surface))
    }

    private func terrainCaption(_ a: ActivityMonitor) -> String {
        switch a.terrain {
        case .climb: return a.grade.map { String(format: "MONTÉE · %.0f %%", $0) } ?? "MONTÉE"
        case .descent: return a.grade.map { String(format: "DESCENTE · %.0f %%", abs($0)) } ?? "DESCENTE"
        case .flat: return "DÉNIVELÉ"
        }
    }

    private var divider: some View { Rectangle().fill(border).frame(width: 1, height: 64) }

    private func metric(_ icon: String, _ value: String, _ unit: String, iconColor: Color? = nil) -> some View {
        VStack(spacing: 6) {
            JIcon(icon, size: 22).foregroundStyle(iconColor ?? accent)
            Text(value).font(.system(size: 32, weight: .heavy).monospacedDigit()).foregroundStyle(text).lineLimit(1).minimumScaleFactor(0.6)
            Text(unit).font(.system(size: 14, weight: .medium)).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Programme / chrono

    private func programCard(_ label: String, _ end: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let remaining = max(0, end.timeIntervalSince(ctx.date))
            let total = coach.planTotal
            let index = coach.planIndex
            let blockSeconds = coach.currentTimerSeconds
            let fraction = blockSeconds > 0 ? 1 - min(1, remaining / Double(blockSeconds)) : 0
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    caption(coach.planTitle?.uppercased() ?? "CHRONO")
                    Spacer()
                    Button { coach.cancelTimer() } label: {
                        JIcon("fermer", size: 16).foregroundStyle(muted).frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 12, y: -12)
                }
                .frame(height: 20)
                HStack(alignment: .lastTextBaseline) {
                    Text(label.capitalized).font(.system(size: 34, weight: .heavy)).foregroundStyle(text).lineLimit(1).minimumScaleFactor(0.6)
                    Spacer()
                    Text(Formatters.elapsed(remaining)).font(.system(size: 48, weight: .heavy).monospacedDigit()).tracking(-1).foregroundStyle(accent)
                }
                if total > 0 {
                    Text("Bloc \(index)/\(total)").font(.system(size: 15, weight: .medium)).foregroundStyle(muted)
                    HStack(spacing: 6) {
                        ForEach(1...total, id: \.self) { i in
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(border)
                                    Capsule().fill(accent).frame(width: geo.size.width * (i < index ? 1 : (i == index ? fraction : 0)))
                                }
                            }
                            .frame(height: 8)
                        }
                    }
                } else {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(border)
                            Capsule().fill(accent).frame(width: geo.size.width * fraction)
                        }
                    }
                    .frame(height: 8)
                }
            }
            .padding(18)
            .background(cardShape(surfaceActive, stroke: accent.opacity(0.18)))
        }
    }

    // MARK: Jeffrey

    /// Jeffrey est actif dès la connexion : pas de bouton à presser, on lui parle quand on veut.
    private var jeffreyCard: some View {
        Button { showTalk = true } label: {
            HStack(alignment: .center, spacing: 14) {
                JeffreyVoiceView(speaking: coach.coachSpeaking, size: 40)
                    .scaleEffect(coach.userSpeaking ? 1.06 : 1)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: coach.userSpeaking)
                VStack(alignment: .leading, spacing: 5) {
                    Text(coach.phase == .connecting ? "JEFFREY ARRIVE" : (coach.coachSpeaking ? "JEFFREY TE PARLE" : (coach.userSpeaking ? "JEFFREY T'ÉCOUTE" : "JEFFREY")))
                        .font(.system(size: 12, weight: .semibold)).tracking(2)
                        .foregroundStyle(coach.coachSpeaking || coach.userSpeaking ? accent : muted)
                    Text(coach.lastCoachLine ?? (coach.phase == .connecting ? "Connexion en cours…" : "Parle-lui quand tu veux, il t'entend."))
                        .font(.system(size: 17, weight: .medium)).foregroundStyle(text)
                        .multilineTextAlignment(.leading).lineLimit(3)
                }
                Spacer(minLength: 8)
                JIcon("conversation", size: 20).foregroundStyle(text)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.white.opacity(0.06)).overlay(Circle().strokeBorder(border)))
            }
            .padding(16)
            .background(cardShape(surface))
        }
        .buttonStyle(.plain)
    }

    private func referenceCard(_ r: ReferenceStatus) -> some View {
        HStack(spacing: 12) {
            JIcon("refaire-parcours", size: 20).foregroundStyle(accent)
            Text(r.offRoute ? "Hors tracé" : "\(r.progressText) · 500 m : \(r.reliefText)")
            Spacer()
            if let g = r.ghostText, !r.offRoute {
                Text(g).font(.system(size: 15, weight: .heavy)).foregroundStyle((r.ghostDelta ?? 0) >= 0 ? accent : danger)
            }
        }
        .font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(muted)
        .padding(16)
        .background(cardShape(surface))
    }

    // MARK: Musique

    private var musicCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                JIcon("musique", size: 22).foregroundStyle(text).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ta musique").font(.system(size: 17, weight: .bold)).foregroundStyle(text)
                    Text(musicSubtitle).font(.system(size: 14, weight: .medium)).foregroundStyle(muted).lineLimit(1)
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
                } else {
                    Button { withAnimation(.snappy) { showMusicApps.toggle() } } label: {
                        HStack(spacing: 6) {
                            Text("Ouvrir").font(.system(size: 16, weight: .medium)).foregroundStyle(text)
                            JIcon("suivant", size: 14).foregroundStyle(muted).rotationEffect(.degrees(showMusicApps ? 90 : 0))
                        }
                        .frame(height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if showMusicApps, music.title == nil {
                // Lecteurs tiers : iOS ne laisse pas afficher leur titre, on ouvre l'app (le dernier lancé en premier).
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(music.suggestedApps) { app in
                            Button { music.open(app) } label: {
                                HStack(spacing: 6) { JIcon("musique", size: 14); Text(app.name) }
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(music.lastApp == app.id ? bg : text)
                                    .padding(.horizontal, 14).frame(height: 36)
                                    .background(Capsule().fill(music.lastApp == app.id ? accent : Color.white.opacity(0.08)))
                            }
                        }
                        Button {
                            if !music.authorized { music.requestAuthorization() }
                            music.togglePlayPause()
                        } label: {
                            HStack(spacing: 6) { JIcon("lecture", size: 14); Text("Apple Music") }
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(text)
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(cardShape(surface))
        .onAppear { music.requestAuthorization() }
    }

    private var musicSubtitle: String {
        if let t = music.title { return "\(t)\(music.artist.map { " · \($0)" } ?? "")" }
        if music.otherAudioPlaying {
            let name = music.suggestedApps.first(where: { $0.id == music.lastApp })?.name ?? "une autre app"
            return "En lecture dans \(name)"
        }
        return "Rien en lecture"
    }

    private func musicButton(_ icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            JIcon(icon, size: prominent ? 16 : 13)
                .foregroundStyle(prominent ? bg : text)
                .frame(width: prominent ? 40 : 34, height: prominent ? 40 : 34)
                .background(Circle().fill(prominent ? accent : Color.white.opacity(0.08)))
        }
    }

    // MARK: Actions

    /// Pause est l'action principale ; Terminer reste distinct (contour, couleur d'alerte).
    private var controls: some View {
        HStack(spacing: 12) {
            Button { coach.togglePause() } label: {
                HStack(spacing: 10) { JIcon(coach.isPaused ? "lecture" : "pause", size: 20); Text(coach.isPaused ? "Reprendre" : "Pause") }
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(bg)
                    .frame(maxWidth: .infinity).frame(height: 60).background(Capsule().fill(accent))
            }
            .disabled(coach.phase != .live)
            .opacity(coach.phase == .live ? 1 : 0.5)
            Button { coach.stop() } label: {
                HStack(spacing: 10) { JIcon("arreter", size: 18); Text("Terminer") }
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(danger)
                    .frame(maxWidth: .infinity).frame(height: 60)
                    .background(Capsule().strokeBorder(danger.opacity(0.7), lineWidth: 1.5))
            }
            .disabled(coach.phase == .ending)
        }
        .padding(.top, 4)
    }

    // MARK: Helpers

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).tracking(2).foregroundStyle(muted).lineLimit(1)
    }

    private func cardShape(_ fill: Color, stroke: Color? = nil) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke ?? border, lineWidth: 1))
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
                JeffreyVoiceView(speaking: coach.coachSpeaking, size: 120)
                    .shadow(color: Theme.lime.opacity(coach.coachSpeaking ? 0.55 : 0.3), radius: 24)
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
                HStack(spacing: 8) {
                    JIcon("micro", size: 14).foregroundStyle(Theme.citron)
                    Text(coach.userSpeaking ? "Je t'entends…" : "Micro ouvert en continu").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
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
