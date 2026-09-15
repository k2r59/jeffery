import SwiftUI
import HealthKit
import MapKit
import CoreLocation

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var history = WorkoutHistory()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if history.isLoading && history.workouts.isEmpty {
                    ProgressView("Lecture de Santé…").tint(Theme.lime)
                } else if history.workouts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "figure.run.square.stack").font(.system(size: 40)).foregroundStyle(Theme.muted)
                        Text(history.errorMessage ?? "Aucune séance sur les 90 derniers jours.")
                            .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List(history.workouts, id: \.uuid) { w in
                        NavigationLink { WorkoutDetailView(workout: w, history: history) } label: { row(w) }
                            .listRowBackground(Theme.surface)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Séances")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await history.load() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.lime)
        .task { await history.load() }
    }

    private func row(_ w: HKWorkout) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: w.workoutActivityType))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.lime)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.surfaceRaised))
            VStack(alignment: .leading, spacing: 3) {
                Text(WorkoutKind(activityType: w.workoutActivityType).label)
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                Text(w.startDate.formatted(date: .abbreviated, time: .shortened) + " · " + WorkoutHistory.sourceLabel(w))
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Formatters.elapsed(w.duration)).font(.system(.body, design: .rounded).weight(.bold).monospacedDigit())
                if let d = WorkoutHistory.distanceMeters(w) {
                    Text(Formatters.distance(d)).font(.caption).foregroundStyle(Theme.ice)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(for t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .cycling: return "figure.outdoor.cycle"
        case .hiking: return "figure.hiking"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "dumbbell.fill"
        case .highIntensityIntervalTraining: return "bolt.heart.fill"
        default: return "figure.mixed.cardio"
        }
    }
}

struct WorkoutDetailView: View {
    let workout: HKWorkout
    @ObservedObject var history: WorkoutHistory
    @State private var locations: [CLLocation] = []
    @State private var averageHR: Double?
    @State private var loaded = false
    @State private var routeSource: String?
    @State private var isReference = false

    private var coordinates: [CLLocationCoordinate2D] {
        locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < 60 }.map(\.coordinate)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    mapCard
                    referenceButton
                    statsGrid
                }
                .padding(18)
            }
        }
        .navigationTitle(WorkoutKind(activityType: workout.workoutActivityType).label)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            async let r = history.route(for: workout)
            async let hr = history.averageHeartRate(for: workout)
            var locs = await r
            routeSource = locs.isEmpty ? nil : "Santé"
            if locs.count < 2, let local = LocalRoute.matching(start: workout.startDate, end: workout.endDate) {
                locs = local.locations
                routeSource = "GPS iPhone (WatchCoach)"
            }
            locations = locs
            averageHR = await hr
        }
    }

    private var referenceButton: some View {
        Group {
            if coordinates.count >= 2 {
                Button {
                    if isReference {
                        ReferenceRoute.clear()
                        isReference = false
                    } else if let ref = ReferenceRoute.make(
                        name: "\(WorkoutKind(activityType: workout.workoutActivityType).label) du \(workout.startDate.formatted(date: .abbreviated, time: .omitted))",
                        date: workout.startDate, locations: locations) {
                        ref.save()
                        isReference = true
                    }
                } label: {
                    Label(isReference ? "Parcours de référence actif · retirer" : "Utiliser comme parcours de référence",
                          systemImage: isReference ? "flag.checkered.circle.fill" : "flag.checkered")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isReference ? Theme.background : .white)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(Capsule().fill(isReference ? Theme.lime : Theme.surfaceRaised))
                }
                .onAppear { isReference = ReferenceRoute.load()?.date == workout.startDate }
            }
        }
    }

    private var mapCard: some View {
        Group {
            if coordinates.count >= 2 {
                Map {
                    MapPolyline(coordinates: coordinates)
                        .stroke(Theme.lime, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    if let first = coordinates.first {
                        Annotation("Départ", coordinate: first) {
                            Circle().fill(Theme.ice).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                    if let last = coordinates.last {
                        Annotation("Arrivée", coordinate: last) {
                            Circle().fill(Theme.pulse).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: loaded && locations.isEmpty ? "location.slash" : "location")
                        .font(.system(size: 30)).foregroundStyle(Theme.muted)
                    Text(loaded ? "Pas de tracé GPS pour cette séance (séance en intérieur, ou pas encore synchronisée depuis la montre)." : "Chargement du tracé…")
                        .font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).frame(height: 180)
                .card()
            }
        }
    }

    private var statsGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 10) {
            stat("DURÉE", Formatters.elapsed(workout.duration), Theme.lime)
            stat("DISTANCE", WorkoutHistory.distanceMeters(workout).map(Formatters.distance) ?? "--", Theme.ice)
            stat("ALLURE MOY.", pace ?? "--", Theme.lime)
            stat("FC MOYENNE", averageHR.map { "\(Int($0)) bpm" } ?? "--", Theme.pulse)
            stat("ÉNERGIE", WorkoutHistory.energyKcal(workout).map { "\(Int($0)) kcal" } ?? "--", Theme.ember)
            stat("DÉNIVELÉ +", locations.isEmpty ? "--" : "\(Int(WorkoutHistory.elevationGain(locations))) m", Theme.ice)
            stat("DÉBUT", workout.startDate.formatted(date: .omitted, time: .shortened), Theme.muted)
            stat("SOURCE", WorkoutHistory.sourceLabel(workout), Theme.muted)
            if let routeSource { stat("TRACÉ", routeSource, Theme.muted) }
        }
    }

    private var pace: String? {
        guard let d = WorkoutHistory.distanceMeters(workout), workout.duration > 0 else { return nil }
        return Formatters.pace(speedMetersPerSecond: d / workout.duration)
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
            Text(value).font(.system(.title3, design: .rounded).weight(.black).monospacedDigit()).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
    }
}
