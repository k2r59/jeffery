import Foundation

/// Catalogue de séances types, par sport et par niveau. Jeffrey les propose à l'oral quand on lui demande des
/// exercices (outil suggest_workouts) puis les fait dérouler bloc par bloc avec le chronomètre (outil start_workout).
struct WorkoutBlock: Codable, Equatable {
    var label: String
    var seconds: Int
    var repeats: Int = 1
    var restSeconds: Int = 0

    var totalSeconds: Int { seconds * repeats + restSeconds * max(0, repeats - 1) }

    /// « 30 s », « 1 min », « 1 min 30 », « 5 min ».
    static func short(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        let m = seconds / 60, r = seconds % 60
        return r == 0 ? "\(m) min" : "\(m) min \(r)"
    }

    var summary: String {
        let d = Self.short(seconds)
        if repeats > 1 {
            return restSeconds > 0 ? "\(repeats) × (\(label) \(d) / récup \(Self.short(restSeconds)))" : "\(repeats) × \(label) \(d)"
        }
        return restSeconds > 0 ? "\(label) \(d) puis récup \(Self.short(restSeconds))" : "\(label) \(d)"
    }
}

struct Workout: Identifiable, Equatable {
    let id: String
    let kind: WorkoutKind
    let level: AthleteLevel
    let title: String
    let blocks: [WorkoutBlock]

    var totalSeconds: Int { blocks.reduce(0) { $0 + $1.totalSeconds } }
    /// Fractionné : au moins un bloc répété (effort / récup).
    var isInterval: Bool { blocks.contains { $0.repeats > 1 } }
    var summary: String { blocks.map(\.summary).joined(separator: ", ") }

    var toolPayload: [String: Any] {
        ["id": id, "title": title, "minutes": Int((Double(totalSeconds) / 60).rounded()), "plan": summary]
    }
}

enum WorkoutLibrary {
    /// Aucune séance proposée ne descend sous 30 minutes (choix d'Hervé du 23/09) : `LogicTests` le vérifie.
    static let minimumSeconds = 30 * 60

    private static func m(_ minutes: Double) -> Int { Int(minutes * 60) }
    private static func b(_ label: String, _ seconds: Int, x repeats: Int = 1, rest: Int = 0) -> WorkoutBlock {
        WorkoutBlock(label: label, seconds: seconds, repeats: repeats, restSeconds: rest)
    }

    static let all: [Workout] = [
        // Course à pied
        Workout(id: "run-b1", kind: .running, level: .beginner, title: "Marche-course 30 min",
                blocks: [b("marche", m(5)), b("course", 60, x: 8, rest: m(2)), b("marche", m(3))]),
        Workout(id: "run-b3", kind: .running, level: .beginner, title: "1 min / 1 min",
                blocks: [b("marche", m(5)), b("course", 60, x: 10, rest: 60), b("marche", m(6))]),
        Workout(id: "run-b4", kind: .running, level: .beginner, title: "30 s / 1 min, tout doux",
                blocks: [b("marche", m(5)), b("course", 30, x: 12, rest: 60), b("marche", m(8))]),
        Workout(id: "run-b5", kind: .running, level: .beginner, title: "2 min / 1 min",
                blocks: [b("marche", m(5)), b("course", m(2), x: 7, rest: 60), b("marche", m(5))]),
        Workout(id: "run-b2", kind: .running, level: .beginner, title: "Footing tout doux",
                blocks: [b("marche", m(5)), b("course facile", m(20)), b("marche", m(5))]),
        Workout(id: "run-a1", kind: .running, level: .amateur, title: "Footing 35 min",
                blocks: [b("échauffement", m(10)), b("allure confortable", m(20)), b("retour au calme", m(5))]),
        Workout(id: "run-a2", kind: .running, level: .amateur, title: "Fractionné 30/30",
                blocks: [b("échauffement", m(12)), b("vite", 30, x: 14, rest: 30), b("retour au calme", m(8))]),
        Workout(id: "run-c1", kind: .running, level: .confirmed, title: "Seuil 3 × 8 min",
                blocks: [b("échauffement", m(12)), b("seuil", m(8), x: 3, rest: m(2)), b("retour au calme", m(8))]),
        Workout(id: "run-c2", kind: .running, level: .confirmed, title: "Fartlek 45 min",
                blocks: [b("échauffement", m(10)), b("vite", m(2), x: 6, rest: 60), b("allure 10 km", m(5)), b("retour au calme", m(10))]),
        // Marche
        Workout(id: "walk-b1", kind: .walking, level: .beginner, title: "Marche tranquille 30 min",
                blocks: [b("marche tranquille", m(30))]),
        Workout(id: "walk-b2", kind: .walking, level: .beginner, title: "Marche active 35 min",
                blocks: [b("marche tranquille", m(5)), b("marche active", m(25)), b("marche tranquille", m(5))]),
        Workout(id: "walk-a1", kind: .walking, level: .amateur, title: "Marche rapide 40 min",
                blocks: [b("échauffement", m(5)), b("marche rapide", m(30)), b("retour au calme", m(5))]),
        Workout(id: "walk-a2", kind: .walking, level: .amateur, title: "Marche fractionnée",
                blocks: [b("échauffement", m(7)), b("marche rapide", m(2), x: 8, rest: 60), b("retour au calme", m(6))]),
        Workout(id: "walk-c1", kind: .walking, level: .confirmed, title: "Marche sportive 1 h",
                blocks: [b("échauffement", m(5)), b("marche sportive", m(50)), b("retour au calme", m(5))]),
        Workout(id: "walk-c2", kind: .walking, level: .confirmed, title: "Marche en côtes",
                blocks: [b("échauffement", m(10)), b("montée soutenue", m(3), x: 5, rest: m(2)), b("retour au calme", m(10))]),
        // Randonnée
        Workout(id: "hike-b1", kind: .hiking, level: .beginner, title: "Balade 45 min",
                blocks: [b("marche", m(45))]),
        Workout(id: "hike-a1", kind: .hiking, level: .amateur, title: "Rando 1 h 30 avec pause",
                blocks: [b("marche", m(45)), b("pause", m(5)), b("marche", m(40))]),
        Workout(id: "hike-c1", kind: .hiking, level: .confirmed, title: "Rando soutenue 2 h",
                blocks: [b("marche soutenue", m(60)), b("pause", m(5)), b("marche soutenue", m(55))]),
        // Autre
        Workout(id: "other-b1", kind: .other, level: .beginner, title: "Séance douce 30 min",
                blocks: [b("échauffement", m(5)), b("activité", m(20)), b("retour au calme", m(5))]),
        Workout(id: "other-a1", kind: .other, level: .amateur, title: "Séance 30 min",
                blocks: [b("échauffement", m(5)), b("activité", m(20)), b("retour au calme", m(5))]),
        Workout(id: "other-c1", kind: .other, level: .confirmed, title: "Séance 45 min",
                blocks: [b("échauffement", m(10)), b("activité soutenue", m(30)), b("retour au calme", m(5))]),
    ]

    static func workouts(kind: WorkoutKind, level: AthleteLevel) -> [Workout] {
        let exact = all.filter { $0.kind == kind && $0.level == level }
        if !exact.isEmpty { return exact }
        return all.filter { $0.kind == .other && $0.level == level }
    }

    static func workout(id: String) -> Workout? { all.first { $0.id == id } }
}
