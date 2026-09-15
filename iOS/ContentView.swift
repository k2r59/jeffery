import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var coach: CoachSession
    @AppStorage(Prefs.kind) private var kindRaw: String = WorkoutKind.running.rawValue
    @AppStorage(Prefs.mode) private var modeRaw: String = CaptureMode.companion.rawValue
    @State private var showSettings = false

    private var kind: WorkoutKind { WorkoutKind(rawValue: kindRaw) ?? .running }
    private var mode: CaptureMode { CaptureMode(rawValue: modeRaw) ?? .companion }
    private var isLive: Bool { coach.phase != .idle }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 14) {
                header
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        watchDiagnostics
                        heroTimer
                        heartCard
                        statsRow
                        transcriptCard
                    }
                }
                controls
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.lime)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task {
            #if DEBUG
            // Test sans interaction (simulateur) : WATCHCOACH_AUTOSTART=1 lance le coach au démarrage.
            if ProcessInfo.processInfo.environment["WATCHCOACH_AUTOSTART"] == "1", coach.phase == .idle {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                coach.start(kind: kind, mode: mode)
            }
            #endif
        }
    }

    // MARK: Fond

    private var backdrop: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            RadialGradient(colors: [Theme.lime.opacity(isLive ? 0.22 : 0.10), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
            RadialGradient(colors: [Theme.ember.opacity(0.16), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 380)
                .ignoresSafeArea()
            TrackLines()
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
                .ignoresSafeArea()
        }
    }

    // MARK: En-tête

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("WATCHCOACH")
                    .font(.display(13, weight: .black))
                    .tracking(4)
                    .foregroundStyle(Theme.muted)
                Text(kind.label.uppercased())
                    .font(.display(28, weight: .black))
                    .foregroundStyle(.white)
            }
            Spacer()
            statusPill
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.surfaceRaised))
            }
            .disabled(isLive)
            .opacity(isLive ? 0.4 : 1)
        }
        .padding(.top, 6)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(coach.phase == .live ? Theme.lime : (coach.phase == .idle ? Theme.muted : Theme.ember))
                .frame(width: 8, height: 8)
                .shadow(color: coach.phase == .live ? Theme.lime : .clear, radius: 6)
            Text(coach.status)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Image(systemName: coach.connectivity.isReachable ? "applewatch.radiowaves.left.and.right" : "applewatch.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(coach.connectivity.isReachable ? Theme.lime : Theme.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.surfaceRaised))
    }

    // MARK: Diagnostic montre

    private var watchDiagnostics: some View {
        let c = coach.connectivity
        return HStack(spacing: 10) {
            diagChip("Appairée", ok: c.isPaired)
            diagChip("App installée", ok: c.isWatchAppInstalled)
            diagChip("Joignable", ok: c.isReachable)
            Spacer()
            Button {
                if let url = URL(string: "itms-watch://") { UIApplication.shared.open(url) }
            } label: {
                Image(systemName: "applewatch.side.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.surfaceRaised))
            }
        }
        .padding(.horizontal, 4)
    }

    private func diagChip(_ title: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ok ? Theme.lime : Theme.pulse).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10, weight: .heavy)).tracking(0.5)
        }
        .foregroundStyle(ok ? .white : Theme.muted)
    }

    // MARK: Chrono

    private var heroTimer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let s = coach.latest
            let elapsed = liveElapsed(s, now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Formatters.elapsed(elapsed))
                        .font(.display(72, weight: .black).monospacedDigit())
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Spacer()
                    speakingIndicator
                }
                HStack(spacing: 8) {
                    Label(s?.mode == .owned ? "Séance WatchCoach" : "Compagnon Exercice", systemImage: s?.mode == .owned ? "record.circle" : "figure.run.circle")
                    if s?.state == .paused {
                        Text("· EN PAUSE").foregroundStyle(Theme.ember)
                    }
                    if let s {
                        Text("· reçu il y a \(Int(max(0, context.date.timeIntervalSince(s.timestamp)))) s")
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
            }
            .card()
        }
    }

    private func liveElapsed(_ s: MetricsSnapshot?, now: Date) -> TimeInterval {
        guard let s else { return 0 }
        guard s.state == .running else { return s.elapsed }
        return s.elapsed + max(0, now.timeIntervalSince(s.timestamp))
    }

    private var speakingIndicator: some View {
        HStack(spacing: 8) {
            if coach.userSpeaking {
                Image(systemName: "mic.fill")
                    .foregroundStyle(Theme.ice)
                    .symbolEffect(.pulse, isActive: true)
            }
            if coach.coachSpeaking {
                Image(systemName: "waveform")
                    .foregroundStyle(Theme.lime)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }
        }
        .font(.system(size: 22, weight: .bold))
    }

    // MARK: Cœur et zones

    private var heartCard: some View {
        let s = coach.latest
        let zone = coach.currentZone
        let color = Theme.zoneColor(zone)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.pulse)
                    .symbolEffect(.pulse.byLayer, options: .repeating, isActive: s?.heartRate != nil && s?.state == .running)
                Text(s?.heartRate.map { "\(Int($0))" } ?? "--")
                    .font(.display(56, weight: .black).monospacedDigit())
                    .foregroundStyle(.white)
                Text("bpm")
                    .font(.display(16, weight: .bold))
                    .foregroundStyle(Theme.muted)
                Spacer()
                if let zone {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(zone.label)
                            .font(.display(30, weight: .black))
                            .foregroundStyle(color)
                            .shadow(color: color.opacity(0.6), radius: 10)
                        Text(zone.description)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            HStack(spacing: 5) {
                ForEach(HeartRateZone.allCases, id: \.rawValue) { z in
                    let active = zone == z
                    Capsule()
                        .fill(Theme.zoneColor(z).opacity(active ? 1 : 0.22))
                        .frame(height: active ? 10 : 6)
                        .shadow(color: active ? Theme.zoneColor(z).opacity(0.8) : .clear, radius: 8)
                        .animation(.spring(duration: 0.4), value: zone)
                }
            }
        }
        .card()
    }

    // MARK: Stats

    private var statsRow: some View {
        let s = coach.latest
        return HStack(spacing: 10) {
            statTile("DISTANCE", s?.distance.map(Formatters.distance) ?? "--", icon: "point.topleft.down.to.point.bottomright.curvepath.fill", color: Theme.ice)
            statTile("ALLURE", coach.pace?.replacingOccurrences(of: " /km", with: "") ?? "--", unit: "/km", icon: "speedometer", color: Theme.lime)
            statTile("ÉNERGIE", s?.activeEnergy.map { "\(Int($0))" } ?? "--", unit: "kcal", icon: "flame.fill", color: Theme.ember)
        }
    }

    private func statTile(_ title: String, _ value: String, unit: String? = nil, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).tracking(1.5)
            }
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.display(24, weight: .black).monospacedDigit())
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let unit { Text(unit).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
    }

    // MARK: Conversation

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("COACH").font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
                Spacer()
                if let err = coach.errorMessage {
                    Text(err).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.pulse).lineLimit(2)
                }
            }
            if coach.transcript.isEmpty {
                Text(isLive ? "Le coach arrive…" : "Mets tes écouteurs, lance ta séance sur la montre, et appuie sur Go.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(coach.transcript) { line in
                                bubble(line).id(line.id)
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 260)
                    .onChange(of: coach.transcript) { _, lines in
                        if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }
        }
        .card()
    }

    @ViewBuilder
    private func bubble(_ line: TranscriptLine) -> some View {
        switch line.role {
        case .info:
            Text(line.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        case .coach:
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: "figure.run")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.lime))
                Text(line.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surfaceRaised))
                Spacer(minLength: 30)
            }
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(line.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.ice))
            }
        }
    }

    // MARK: Contrôles

    private var controls: some View {
        VStack(spacing: 12) {
            if coach.phase == .idle {
                modeToggle
                kindChips
                Button { coach.start(kind: kind, mode: mode) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mic.fill")
                        Text("GO, COACH")
                            .tracking(2)
                    }
                    .font(.display(20, weight: .black))
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(Capsule().fill(Theme.startGradient))
                    .shadow(color: Theme.lime.opacity(0.45), radius: 18, y: 6)
                }
            } else {
                HStack(spacing: 12) {
                    Button { coach.cue(reason: "demande manuelle de l'utilisateur") } label: {
                        Label("POINT COACH", systemImage: "bubble.left.fill")
                            .font(.display(14, weight: .black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Capsule().fill(Theme.surfaceRaised))
                    }
                    .disabled(coach.phase != .live)
                    Button { coach.stop() } label: {
                        Label("TERMINER", systemImage: "stop.fill")
                            .font(.display(14, weight: .black))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Capsule().fill(Theme.pulse))
                            .shadow(color: Theme.pulse.opacity(0.4), radius: 14, y: 5)
                    }
                    .disabled(coach.phase == .ending)
                }
            }
        }
    }

    private var modeToggle: some View {
        HStack(spacing: 4) {
            modeButton("SUIVRE EXERCICE", icon: "applewatch", value: .companion)
            modeButton("SÉANCE WATCHCOACH", icon: "record.circle", value: .owned)
        }
        .padding(4)
        .background(Capsule().fill(Theme.surface))
    }

    private func modeButton(_ title: String, icon: String, value: CaptureMode) -> some View {
        let selected = mode == value
        return Button { withAnimation(.snappy) { modeRaw = value.rawValue } } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).tracking(0.5)
            }
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(selected ? Theme.background : .white.opacity(0.7))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(Capsule().fill(selected ? Color.white : .clear))
        }
    }

    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(WorkoutKind.allCases) { k in
                    let selected = k == kind
                    Button { withAnimation(.snappy) { kindRaw = k.rawValue } } label: {
                        Text(k.label)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(selected ? Theme.background : .white)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule().fill(selected ? Theme.lime : Theme.surfaceRaised))
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// Lignes de piste en diagonale, très discrètes, en fond.
struct TrackLines: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 46
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + rect.height * 0.6, y: rect.minY))
            x += step
        }
        return p
    }
}
