import Foundation
import HealthKit
import CoreLocation
import Combine

/// Séances enregistrées dans Santé (app Exercice ou WatchCoach) et leurs tracés GPS.
@MainActor
final class WorkoutHistory: ObservableObject {
    @Published private(set) var workouts: [HKWorkout] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType(), HKSeriesType.workoutRoute(), HKQuantityType(.heartRate),
         HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling)]
    }

    func load(days: Int = 90) async {
        guard HKHealthStore.isHealthDataAvailable(), ProcessInfo.processInfo.environment["WATCHCOACH_NO_HEALTH"] == nil else { errorMessage = "Santé indisponible"; return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        workouts = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: 100, sortDescriptors: [sort]) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }

    /// Toutes les positions du tracé associé à la séance (vide si la séance n'a pas de GPS).
    func route(for workout: HKWorkout) async -> [CLLocation] {
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }
        var all: [CLLocation] = []
        for route in routes {
            let locations: [CLLocation] = await withCheckedContinuation { continuation in
                var acc: [CLLocation] = []
                let query = HKWorkoutRouteQuery(route: route) { _, batch, done, _ in
                    if let batch { acc.append(contentsOf: batch) }
                    if done { continuation.resume(returning: acc) }
                }
                store.execute(query)
            }
            all.append(contentsOf: locations)
        }
        return all.sorted { $0.timestamp < $1.timestamp }
    }

    func averageHeartRate(for workout: HKWorkout) async -> Double? {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [])
            let query = HKStatisticsQuery(quantityType: HKQuantityType(.heartRate), quantitySamplePredicate: predicate,
                                          options: .discreteAverage) { _, stats, _ in
                continuation.resume(returning: stats?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())))
            }
            store.execute(query)
        }
    }

    // MARK: Helpers d'affichage

    static func distanceMeters(_ w: HKWorkout) -> Double? {
        for type in [HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling)] {
            if let d = w.statistics(for: type)?.sumQuantity()?.doubleValue(for: .meter()), d > 0 { return d }
        }
        return nil
    }

    static func energyKcal(_ w: HKWorkout) -> Double? {
        w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
    }

    static func sourceLabel(_ w: HKWorkout) -> String {
        let name = w.sourceRevision.source.name
        return name.localizedCaseInsensitiveContains("watchcoach") ? "WatchCoach" : name
    }

    /// Dénivelé positif cumulé (m), en ignorant les positions à l'altitude imprécise.
    static func elevationGain(_ locations: [CLLocation]) -> Double {
        var gain = 0.0
        var last: Double?
        for l in locations where l.verticalAccuracy >= 0 && l.verticalAccuracy < 30 {
            if let p = last, l.altitude > p { gain += l.altitude - p }
            last = l.altitude
        }
        return gain
    }
}
