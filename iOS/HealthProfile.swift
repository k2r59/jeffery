import Foundation
import HealthKit

/// Lecture du profil dans l'app Santé : date de naissance, taille, poids (dernières valeurs enregistrées).
enum HealthProfile {
    struct Result {
        var age: Int?
        var heightCm: Double?
        var weightKg: Double?
    }

    static let readTypes: Set<HKObjectType> = [
        HKCharacteristicType(.dateOfBirth),
        HKQuantityType(.height),
        HKQuantityType(.bodyMass),
    ]

    static func fetch(store: HKHealthStore = HKHealthStore()) async -> Result {
        guard HKHealthStore.isHealthDataAvailable() else { return Result() }
        _ = try? await store.requestAuthorization(toShare: [], read: readTypes)
        var result = Result()
        if let dob = try? store.dateOfBirthComponents(), let date = Calendar.current.date(from: dob) {
            result.age = Calendar.current.dateComponents([.year], from: date, to: Date()).year
        }
        result.heightCm = await latest(store: store, type: HKQuantityType(.height), unit: .meterUnit(with: .centi))
        result.weightKg = await latest(store: store, type: HKQuantityType(.bodyMass), unit: .gramUnit(with: .kilo))
        return result
    }

    private static func latest(store: HKHealthStore, type: HKQuantityType, unit: HKUnit) async -> Double? {
        await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }
}
