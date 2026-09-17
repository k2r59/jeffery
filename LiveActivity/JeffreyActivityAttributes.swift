import Foundation
import ActivityKit

/// État de séance partagé entre l'app et l'extension de widget (Live Activity).
struct JeffreyActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var startedAt: Date            // pour le chrono en direct (Text(timerInterval:))
        var paused: Bool
        var elapsedFrozen: TimeInterval
        var heartRate: Int?
        var distanceMeters: Double?
        var goalLabel: String?
        var remaining: String?
        var progress: Double
        var coachState: String         // "arrive", "ecoute", "parle"
        var lastLine: String?
        var timerLabel: String?
        var timerEndsAt: Date?
    }
    var kindLabel: String
}
