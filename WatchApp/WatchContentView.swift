import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var workout: WorkoutManager
    @State private var page = 1

    var body: some View {
        if workout.isActive {
            // Glisser vers la droite depuis les métriques révèle les commandes, comme l'app Exercice.
            TabView(selection: $page) {
                controlsPage.tag(0)
                ScrollView { liveView }.tag(1)
            }
            .tabViewStyle(.page)
            .onAppear { page = 1 }
        } else {
            NavigationStack {
                ScrollView { startView }
                    .navigationTitle("Jeffrey")
            }
        }
    }

    // MARK: Panneau de commandes (page de gauche)

    private var controlsPage: some View {
        let s = workout.snapshot
        return VStack(spacing: 14) {
            HStack(spacing: 18) {
                controlButton("xmark", "Terminer", .red) {
                    workout.end()
                }
                if s.state == .paused {
                    controlButton("play.fill", "Reprendre", .green) {
                        workout.resume(); page = 1
                    }
                } else {
                    controlButton("pause.fill", "Pause", .yellow) {
                        workout.pause()
                    }
                }
            }
            if workout.needsBackgroundExtension {
                Button {
                    workout.extendBackground(); page = 1
                } label: {
                    Label("Prolonger", systemImage: "clock.arrow.circlepath")
                }
                .tint(.green)
            }
            Text(s.mode == .companion ? "Compagnon Exercice" : "Séance WatchCoach")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }

    private func controlButton(_ icon: String, _ title: String, _ color: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .bold))
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)
            .foregroundStyle(color)
            .background(Circle().fill(color.opacity(0.25)))
            .clipShape(Circle())
            Text(title).font(.caption2)
        }
    }

    // MARK: Écran de démarrage

    private var startView: some View {
        VStack(spacing: 10) {
            Picker("Type", selection: $workout.selectedKind) {
                ForEach(WorkoutKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.navigationLink)

            JeffreyWordmark(size: 16)
            Button {
                workout.startCompanion(kind: workout.selectedKind)
            } label: {
                Label("Suivre l'app Exercice", systemImage: "figure.run.circle")
            }
            .tint(.green)

            Button {
                workout.startOwned(kind: workout.selectedKind)
            } label: {
                Label("Séance ici", systemImage: "play.fill")
            }
            .tint(.orange)

            if !workout.statusMessage.isEmpty {
                Text(workout.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Séance en cours

    private var liveView: some View {
        let s = workout.snapshot
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                JeffreyMark(size: 22)
                Spacer()
                Text(s.kind.label.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(.secondary)
            }
            Text(Formatters.elapsed(s.elapsed))
                .font(.system(.title2, design: .rounded).monospacedDigit())
                .foregroundStyle(.yellow)

            metricRow("heart.fill", s.heartRate.map { "\(Int($0)) bpm" } ?? "-- bpm", .red)
            if s.kind.usesDistance {
                metricRow("point.topleft.down.to.point.bottomright.curvepath", s.distance.map(Formatters.distance) ?? "--", .blue)
                if let v = s.speed, let pace = Formatters.pace(speedMetersPerSecond: v) {
                    metricRow("speedometer", pace, .cyan)
                }
            }
            metricRow("flame.fill", s.activeEnergy.map { "\(Int($0)) kcal" } ?? "-- kcal", .orange)

            Text(s.mode == .companion ? "Compagnon Exercice" : "Séance WatchCoach")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if s.state == .paused {
                Text("En pause").font(.caption).foregroundStyle(.yellow)
            }
            if !workout.statusMessage.isEmpty {
                Text(workout.statusMessage).font(.caption2).foregroundStyle(.secondary)
            }

            Text("← glisse pour les commandes")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }

    private func metricRow(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(.body, design: .rounded).monospacedDigit())
        }
    }
}
