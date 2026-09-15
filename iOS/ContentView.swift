import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var coach: CoachSession
    @AppStorage(Prefs.kind) private var kindRaw: String = WorkoutKind.running.rawValue
    @AppStorage(Prefs.mode) private var modeRaw: String = CaptureMode.companion.rawValue
    @State private var showSettings = false

    private var kind: WorkoutKind { WorkoutKind(rawValue: kindRaw) ?? .running }
    private var mode: CaptureMode { CaptureMode(rawValue: modeRaw) ?? .companion }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                statusBar
                metricsGrid
                transcriptList
                controls
            }
            .padding()
            .navigationTitle("WatchCoach")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .disabled(coach.phase != .idle)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    // MARK: Sous-vues

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(coach.phase == .live ? Color.green : (coach.phase == .idle ? Color.gray : Color.orange))
                .frame(width: 10, height: 10)
            Text(coach.status).font(.subheadline)
            Spacer()
            Image(systemName: coach.connectivity.isReachable ? "applewatch.radiowaves.left.and.right" : "applewatch.slash")
                .foregroundStyle(coach.connectivity.isReachable ? .green : .secondary)
            if coach.coachSpeaking { Image(systemName: "waveform").foregroundStyle(.blue) }
            if coach.userSpeaking { Image(systemName: "mic.fill").foregroundStyle(.red) }
        }
    }

    private var metricsGrid: some View {
        let s = coach.latest
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            tile("Fréquence", s?.heartRate.map { "\(Int($0))" } ?? "--", unit: "bpm", detail: coach.currentZone.map { "\($0.label) · \($0.description)" }, color: .red)
            tile("Temps", s.map { Formatters.elapsed($0.elapsed) } ?? "0:00", unit: nil, detail: s?.state == .paused ? "en pause" : s?.mode.label, color: .yellow)
            tile("Distance", s?.distance.map(Formatters.distance) ?? "--", unit: nil, detail: coach.pace.map { "allure \($0)" }, color: .blue)
            tile("Énergie", s?.activeEnergy.map { "\(Int($0))" } ?? "--", unit: "kcal", detail: s.map { "reçu il y a \(Int(Date().timeIntervalSince($0.timestamp))) s" }, color: .orange)
        }
    }

    private func tile(_ title: String, _ value: String, unit: String?, detail: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(.title, design: .rounded).weight(.semibold).monospacedDigit()).foregroundStyle(color)
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            Text(detail ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(coach.transcript) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: icon(for: line.role)).foregroundStyle(tint(for: line.role)).frame(width: 18)
                            Text(line.text).font(line.role == .info ? .caption : .body)
                                .foregroundStyle(line.role == .info ? .secondary : .primary)
                        }
                        .id(line.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: coach.transcript) { _, lines in
                if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func icon(for role: TranscriptLine.Role) -> String {
        switch role {
        case .user: return "person.fill"
        case .coach: return "figure.run"
        case .info: return "info.circle"
        }
    }

    private func tint(for role: TranscriptLine.Role) -> Color {
        switch role {
        case .user: return .blue
        case .coach: return .green
        case .info: return .secondary
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let err = coach.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if coach.phase == .idle {
                Picker("Mode", selection: $modeRaw) {
                    Text("Suivre l'app Exercice").tag(CaptureMode.companion.rawValue)
                    Text("Séance par WatchCoach").tag(CaptureMode.owned.rawValue)
                }
                .pickerStyle(.segmented)
                Picker("Type", selection: $kindRaw) {
                    ForEach(WorkoutKind.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
                Text(mode == .companion
                     ? "Lance ta séance dans l'app Exercice de la montre ; WatchCoach lit les données à côté."
                     : "WatchCoach démarre et enregistre la séance sur la montre (données plus fréquentes).")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button {
                    coach.start(kind: kind, mode: mode)
                } label: {
                    Label("Démarrer le coach", systemImage: "mic.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                HStack {
                    Button {
                        coach.cue(reason: "demande manuelle de l'utilisateur")
                    } label: {
                        Label("Point coach", systemImage: "bubble.left.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(coach.phase != .live)
                    Button(role: .destructive) {
                        coach.stop()
                    } label: {
                        Label("Terminer", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(coach.phase == .ending)
                }
                .controlSize(.large)
            }
        }
    }
}
