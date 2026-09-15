import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var workout: WorkoutManager

    var body: some View {
        NavigationStack {
            ScrollView {
                if workout.isActive {
                    liveView
                } else {
                    startView
                }
            }
            .navigationTitle("WatchCoach")
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

            if workout.needsBackgroundExtension {
                Button("Prolonger l'arrière-plan") { workout.extendBackground() }
                    .tint(.green)
            }

            HStack {
                if s.mode == .owned {
                    if s.state == .paused {
                        Button { workout.resume() } label: { Image(systemName: "play.fill") }.tint(.green)
                    } else {
                        Button { workout.pause() } label: { Image(systemName: "pause.fill") }.tint(.yellow)
                    }
                }
                Button { workout.end() } label: { Image(systemName: "stop.fill") }.tint(.red)
            }
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
