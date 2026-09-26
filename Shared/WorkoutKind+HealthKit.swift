import Foundation
import HealthKit

extension WorkoutKind {
    var activityType: HKWorkoutActivityType {
        switch self {
        case .running: return .running
        case .walking: return .walking
        case .cycling: return .cycling
        case .hiking: return .hiking
        case .functionalStrength: return .functionalStrengthTraining
        case .hiit: return .highIntensityIntervalTraining
        case .other: return .other
        }
    }

    var locationType: HKWorkoutSessionLocationType {
        switch self {
        case .running, .walking, .cycling, .hiking: return .outdoor
        default: return .indoor
        }
    }

    init(activityType: HKWorkoutActivityType) {
        switch activityType {
        case .running: self = .running
        case .walking: self = .walking
        case .cycling: self = .cycling
        case .hiking: self = .hiking
        case .functionalStrengthTraining: self = .functionalStrength
        case .highIntensityIntervalTraining: self = .hiit
        default: self = .other
        }
    }
}
