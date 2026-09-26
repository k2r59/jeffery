import Foundation

/// Point de reprise écrit pendant la séance (Documents/seance-en-cours.json). Si l'app meurt en route (plantage,
/// mémoire, arrêt par iOS), Jeffrey repart de là au lancement suivant : même séance, même objectif, même chrono,
/// mêmes répliques. Effacé à la fin normale de la séance.
struct SessionCheckpoint: Codable, Equatable {
    struct Line: Codable, Equatable {
        var role: String   // "user", "coach", "info"
        var text: String
        var at: Date
    }
    struct TimerState: Codable, Equatable {
        var label: String
        var baseLabel: String
        var index: Int
        var endsAt: Date
        var workSeconds: Int
        var restSeconds: Int
        var repeatsLeft: Int
        var phaseIsWork: Bool
    }
    struct PlanState: Codable, Equatable {
        var title: String
        var queue: [WorkoutBlock]
        var total: Int
        var index: Int
    }

    var kind: WorkoutKind
    var goal: SessionGoal
    var goalReached: Bool
    var halfwayAnnounced: Bool
    var startedAt: Date
    var savedAt: Date
    var transcript: [Line]
    var hrSamples: [Double]
    var zoneSeconds: [Int]
    var lastKmAnnounced: Int
    var lastKmElapsed: TimeInterval
    var timer: TimerState?
    var plan: PlanState?
    var routeID: String?
    var stationarySeconds: TimeInterval
    var climbingSeconds: TimeInterval
    var ascent: Double
    var descent: Double

    /// Au-delà, on ne reprend plus : la séance est close avec ce qu'on a.
    static let maxResumeAge: TimeInterval = 30 * 60

    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("seance-en-cours.json")

    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    func save(to url: URL = SessionCheckpoint.url) {
        guard let data = try? Self.encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load(from url: URL = SessionCheckpoint.url) -> SessionCheckpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SessionCheckpoint.self, from: data)
    }

    static func clear(at url: URL = SessionCheckpoint.url) {
        try? FileManager.default.removeItem(at: url)
    }

    var age: TimeInterval { Date().timeIntervalSince(savedAt) }
    var isResumable: Bool { age < Self.maxResumeAge }
}
