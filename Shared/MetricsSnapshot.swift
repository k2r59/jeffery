import Foundation

/// Type de séance choisi par l'utilisateur (mappé vers HKWorkoutActivityType côté montre).
enum WorkoutKind: String, Codable, CaseIterable, Identifiable {
    case running
    case walking
    case cycling
    case hiking
    case functionalStrength
    case hiit
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .running: return "Course"
        case .walking: return "Marche"
        case .cycling: return "Vélo"
        case .hiking: return "Randonnée"
        case .functionalStrength: return "Renfo"
        case .hiit: return "HIIT"
        case .other: return "Autre"
        }
    }

    /// Libellé injecté dans les instructions du coach.
    var coachLabel: String {
        switch self {
        case .running: return "course à pied"
        case .walking: return "marche"
        case .cycling: return "vélo"
        case .hiking: return "randonnée"
        case .functionalStrength: return "renforcement musculaire"
        case .hiit: return "HIIT (intervalles haute intensité)"
        case .other: return "exercice"
        }
    }

    var usesDistance: Bool {
        switch self {
        case .running, .walking, .cycling, .hiking: return true
        default: return false
        }
    }
}

/// Qui pilote la séance côté montre.
enum CaptureMode: String, Codable {
    /// Notre app montre possède la HKWorkoutSession (données ~1 s).
    case owned
    /// L'app Exercice native possède la séance ; on lit les échantillons qu'elle écrit dans HealthKit.
    case companion

    var label: String {
        switch self {
        case .owned: return "séance pilotée par WatchCoach"
        case .companion: return "compagnon de l'app Exercice"
        }
    }
}

enum SessionState: String, Codable {
    case idle
    case running
    case paused
    case ended
}

/// Instantané des métriques envoyé montre → iPhone.
struct MetricsSnapshot: Codable, Equatable {
    var timestamp: Date
    var elapsed: TimeInterval
    var heartRate: Double?      // bpm
    var activeEnergy: Double?   // kcal cumulées
    var distance: Double?       // mètres cumulés
    var speed: Double?          // m/s instantané (runningSpeed) si dispo
    var mode: CaptureMode
    var kind: WorkoutKind
    var state: SessionState
    /// Date du dernier échantillon HealthKit reçu (mode compagnon : utile pour la latence).
    var lastSampleAt: Date?

    static func idle(kind: WorkoutKind, mode: CaptureMode) -> MetricsSnapshot {
        MetricsSnapshot(timestamp: Date(), elapsed: 0, heartRate: nil, activeEnergy: nil,
                        distance: nil, speed: nil, mode: mode, kind: kind, state: .idle, lastSampleAt: nil)
    }
}

/// Commandes iPhone → montre (capture) et demandes montre → iPhone (télécommande).
enum WatchCommand: String, Codable {
    case start
    case pause
    case resume
    case end
    case requestStart
    case requestPause
    case requestResume
    case requestEnd
}

/// État de la séance iPhone reflété sur la montre.
struct CoachMirror: Codable, Equatable {
    var phase: String            // idle, connecting, live, ending
    var elapsed: TimeInterval
    var timestamp: Date
    var kind: WorkoutKind
    var goalLabel: String?
    var remaining: String?
    var progress: Double
    var goalReached: Bool
    var coachSpeaking: Bool
    var userSpeaking: Bool
    var lastLine: String?
    var heartRate: Double?
    var distance: Double?
    var paused: Bool
    var timerLabel: String? = nil
    var timerEndsAt: Date? = nil

    static let idle = CoachMirror(phase: "idle", elapsed: 0, timestamp: Date(), kind: .running, goalLabel: nil, remaining: nil,
                                  progress: 0, goalReached: false, coachSpeaking: false, userSpeaking: false, lastLine: nil,
                                  heartRate: nil, distance: nil, paused: false)
}

struct WatchCommandPayload: Codable {
    var command: WatchCommand
    var kind: WorkoutKind
    var mode: CaptureMode
}

/// Clés des dictionnaires WatchConnectivity.
enum WCKeys {
    static let metrics = "metrics"   // Data JSON de MetricsSnapshot
    static let command = "command"   // Data JSON de WatchCommandPayload
    static let commandAt = "commandAt" // horodatage (secondes) de la commande déposée dans le contexte
    static let coachState = "coachState" // Data JSON de CoachMirror (iPhone → montre)
}

enum WCCodec {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// Zones de fréquence cardiaque en % de la FC max.
enum HeartRateZone: Int, CaseIterable {
    case z1 = 1, z2, z3, z4, z5

    static func zone(for heartRate: Double, maxHR: Double) -> HeartRateZone {
        guard maxHR > 0 else { return .z1 }
        let pct = heartRate / maxHR
        switch pct {
        case ..<0.60: return .z1
        case ..<0.70: return .z2
        case ..<0.80: return .z3
        case ..<0.90: return .z4
        default: return .z5
        }
    }

    var label: String { "Z\(rawValue)" }

    var description: String {
        switch self {
        case .z1: return "très facile (récupération)"
        case .z2: return "endurance fondamentale"
        case .z3: return "tempo"
        case .z4: return "seuil"
        case .z5: return "maximal"
        }
    }
}

enum Formatters {
    static func elapsed(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Durée « humaine » : 45 min, 1 h 17.
    static func humanDuration(_ t: TimeInterval) -> String {
        let m = Int(max(0, t)) / 60
        return m >= 60 ? String(format: "%d h %02d", m / 60, m % 60) : "\(m) min"
    }

    static func distance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.2f km", meters / 1000) : String(format: "%.0f m", meters)
    }

    /// Allure min/km à partir d'une vitesse en m/s.
    static func pace(speedMetersPerSecond v: Double) -> String? {
        guard v > 0.3 else { return nil }
        let secPerKm = 1000 / v
        guard secPerKm < 3600 else { return nil }
        let m = Int(secPerKm) / 60, s = Int(secPerKm) % 60
        return String(format: "%d:%02d /km", m, s)
    }
}
