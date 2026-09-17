import Foundation

/// Catalogue de séances types, par sport et par niveau. Jeffrey les propose à l'oral quand on lui demande des
/// exercices (outil suggest_workouts) puis les fait dérouler bloc par bloc avec le chronomètre (outil start_workout).
struct WorkoutBlock: Equatable {
    var label: String
    var seconds: Int
    var repeats: Int = 1
    var restSeconds: Int = 0

    var totalSeconds: Int { seconds * repeats + restSeconds * max(0, repeats - 1) }

    var summary: String {
        let d = Formatters.humanDuration(TimeInterval(seconds))
        if repeats > 1 {
            return restSeconds > 0 ? "\(repeats) × (\(label) \(d) / récup \(Formatters.humanDuration(TimeInterval(restSeconds))))" : "\(repeats) × \(label) \(d)"
        }
        return "\(label) \(d)"
    }
}

struct Workout: Identifiable, Equatable {
    let id: String
    let kind: WorkoutKind
    let level: AthleteLevel
    let title: String
    let blocks: [WorkoutBlock]

    var totalSeconds: Int { blocks.reduce(0) { $0 + $1.totalSeconds } }
    var summary: String { blocks.map(\.summary).joined(separator: ", ") }

    var toolPayload: [String: Any] {
        ["id": id, "title": title, "minutes": Int((Double(totalSeconds) / 60).rounded()), "plan": summary]
    }
}

enum WorkoutLibrary {
    private static func m(_ minutes: Double) -> Int { Int(minutes * 60) }
    private static func b(_ label: String, _ seconds: Int, x repeats: Int = 1, rest: Int = 0) -> WorkoutBlock {
        WorkoutBlock(label: label, seconds: seconds, repeats: repeats, restSeconds: rest)
    }

    static let all: [Workout] = [
        // Course à pied
        Workout(id: "run-b1", kind: .running, level: .beginner, title: "Marche-course 20 min",
                blocks: [b("marche", m(5)), b("course", 60, x: 6, rest: 60), b("marche", m(3))]),
        Workout(id: "run-b2", kind: .running, level: .beginner, title: "Footing tout doux",
                blocks: [b("marche", m(3)), b("course facile", m(12)), b("marche", m(3))]),
        Workout(id: "run-a1", kind: .running, level: .amateur, title: "Footing 35 min",
                blocks: [b("échauffement", m(10)), b("allure confortable", m(20)), b("retour au calme", m(5))]),
        Workout(id: "run-a2", kind: .running, level: .amateur, title: "Fractionné 30/30",
                blocks: [b("échauffement", m(10)), b("vite", 30, x: 8, rest: 30), b("retour au calme", m(8))]),
        Workout(id: "run-c1", kind: .running, level: .confirmed, title: "Seuil 3 × 8 min",
                blocks: [b("échauffement", m(12)), b("seuil", m(8), x: 3, rest: m(2)), b("retour au calme", m(8))]),
        Workout(id: "run-c2", kind: .running, level: .confirmed, title: "Fartlek 45 min",
                blocks: [b("échauffement", m(10)), b("vite", m(2), x: 6, rest: 60), b("allure 10 km", m(5)), b("retour au calme", m(10))]),
        // Marche
        Workout(id: "walk-b1", kind: .walking, level: .beginner, title: "Marche tranquille 20 min",
                blocks: [b("marche tranquille", m(20))]),
        Workout(id: "walk-b2", kind: .walking, level: .beginner, title: "Marche active 25 min",
                blocks: [b("marche tranquille", m(5)), b("marche active", m(15)), b("marche tranquille", m(5))]),
        Workout(id: "walk-a1", kind: .walking, level: .amateur, title: "Marche rapide 40 min",
                blocks: [b("échauffement", m(5)), b("marche rapide", m(30)), b("retour au calme", m(5))]),
        Workout(id: "walk-a2", kind: .walking, level: .amateur, title: "Marche fractionnée",
                blocks: [b("échauffement", m(5)), b("marche rapide", m(2), x: 6, rest: 60), b("retour au calme", m(5))]),
        Workout(id: "walk-c1", kind: .walking, level: .confirmed, title: "Marche sportive 1 h",
                blocks: [b("échauffement", m(5)), b("marche sportive", m(50)), b("retour au calme", m(5))]),
        Workout(id: "walk-c2", kind: .walking, level: .confirmed, title: "Marche en côtes",
                blocks: [b("échauffement", m(10)), b("montée soutenue", m(3), x: 5, rest: m(2)), b("retour au calme", m(10))]),
        // Vélo
        Workout(id: "bike-b1", kind: .cycling, level: .beginner, title: "Sortie tranquille 30 min",
                blocks: [b("pédalage souple", m(30))]),
        Workout(id: "bike-b2", kind: .cycling, level: .beginner, title: "Jeu de cadence",
                blocks: [b("échauffement", m(10)), b("cadence élevée", m(3), x: 4, rest: m(2)), b("retour au calme", m(5))]),
        Workout(id: "bike-a1", kind: .cycling, level: .amateur, title: "Endurance 1 h",
                blocks: [b("échauffement", m(10)), b("endurance", m(45)), b("retour au calme", m(5))]),
        Workout(id: "bike-a2", kind: .cycling, level: .amateur, title: "Intervalles 4 × 4 min",
                blocks: [b("échauffement", m(15)), b("soutenu", m(4), x: 4, rest: m(3)), b("retour au calme", m(10))]),
        Workout(id: "bike-c1", kind: .cycling, level: .confirmed, title: "Sweet spot 2 × 20 min",
                blocks: [b("échauffement", m(15)), b("sweet spot", m(20), x: 2, rest: m(5)), b("retour au calme", m(10))]),
        Workout(id: "bike-c2", kind: .cycling, level: .confirmed, title: "Sprints courts",
                blocks: [b("échauffement", m(15)), b("sprint", 30, x: 8, rest: 150), b("retour au calme", m(10))]),
        // Randonnée
        Workout(id: "hike-b1", kind: .hiking, level: .beginner, title: "Balade 45 min",
                blocks: [b("marche", m(45))]),
        Workout(id: "hike-a1", kind: .hiking, level: .amateur, title: "Rando 1 h 30 avec pause",
                blocks: [b("marche", m(45)), b("pause", m(5)), b("marche", m(40))]),
        Workout(id: "hike-c1", kind: .hiking, level: .confirmed, title: "Rando soutenue 2 h",
                blocks: [b("marche soutenue", m(60)), b("pause", m(5)), b("marche soutenue", m(55))]),
        // Renforcement
        Workout(id: "str-b1", kind: .functionalStrength, level: .beginner, title: "Circuit découverte 15 min",
                blocks: [b("échauffement", m(3)), b("squats", 40, x: 3, rest: 20), b("pompes sur les genoux", 40, x: 3, rest: 20),
                         b("gainage", 30, x: 3, rest: 30), b("étirements", m(3))]),
        Workout(id: "str-b2", kind: .functionalStrength, level: .beginner, title: "Bas du corps en douceur",
                blocks: [b("échauffement", m(3)), b("fentes", 40, x: 3, rest: 20), b("pont fessier", 40, x: 3, rest: 20),
                         b("chaise contre le mur", 30, x: 3, rest: 30), b("étirements", m(3))]),
        Workout(id: "str-a1", kind: .functionalStrength, level: .amateur, title: "Circuit complet 25 min",
                blocks: [b("échauffement", m(5)), b("fentes", 45, x: 4, rest: 15), b("pompes", 45, x: 4, rest: 15),
                         b("gainage", 45, x: 4, rest: 15), b("squats sautés", 30, x: 3, rest: 30), b("étirements", m(4))]),
        Workout(id: "str-a2", kind: .functionalStrength, level: .amateur, title: "Haut du corps et gainage",
                blocks: [b("échauffement", m(5)), b("pompes", 40, x: 4, rest: 20), b("dips sur chaise", 40, x: 4, rest: 20),
                         b("gainage latéral", 30, x: 4, rest: 30), b("superman", 40, x: 3, rest: 20), b("étirements", m(4))]),
        Workout(id: "str-c1", kind: .functionalStrength, level: .confirmed, title: "Circuit intense 35 min",
                blocks: [b("échauffement", m(5)), b("burpees", 40, x: 5, rest: 20), b("pompes", 45, x: 5, rest: 15),
                         b("squats sautés", 40, x: 5, rest: 20), b("gainage dynamique", 45, x: 5, rest: 15),
                         b("fentes sautées", 30, x: 4, rest: 30), b("étirements", m(5))]),
        Workout(id: "str-c2", kind: .functionalStrength, level: .confirmed, title: "Force et explosivité",
                blocks: [b("échauffement", m(5)), b("squats pistol assistés", 40, x: 4, rest: 20), b("pompes claquées", 30, x: 4, rest: 30),
                         b("montées de genoux", 45, x: 4, rest: 15), b("gainage bras tendus", 60, x: 3, rest: 30), b("étirements", m(5))]),
        // HIIT
        Workout(id: "hiit-b1", kind: .hiit, level: .beginner, title: "HIIT doux 12 min",
                blocks: [b("échauffement", m(4)), b("effort", 20, x: 6, rest: 40), b("retour au calme", m(3))]),
        Workout(id: "hiit-b2", kind: .hiit, level: .beginner, title: "Intervalles 30/60",
                blocks: [b("échauffement", m(4)), b("effort", 30, x: 5, rest: 60), b("retour au calme", m(3))]),
        Workout(id: "hiit-a1", kind: .hiit, level: .amateur, title: "Tabata, deux blocs",
                blocks: [b("échauffement", m(5)), b("effort", 20, x: 8, rest: 10), b("repos", m(2)), b("effort", 20, x: 8, rest: 10), b("retour au calme", m(4))]),
        Workout(id: "hiit-a2", kind: .hiit, level: .amateur, title: "HIIT 40/20",
                blocks: [b("échauffement", m(5)), b("effort", 40, x: 10, rest: 20), b("retour au calme", m(4))]),
        Workout(id: "hiit-c1", kind: .hiit, level: .confirmed, title: "HIIT 30/15, deux blocs",
                blocks: [b("échauffement", m(5)), b("effort", 30, x: 12, rest: 15), b("repos", m(2)), b("effort", 30, x: 12, rest: 15), b("retour au calme", m(5))]),
        Workout(id: "hiit-c2", kind: .hiit, level: .confirmed, title: "Pyramide",
                blocks: [b("échauffement", m(5)), b("effort", 20, x: 2, rest: 20), b("effort", 40, x: 2, rest: 20), b("effort", 60, x: 2, rest: 30),
                         b("effort", 40, x: 2, rest: 20), b("effort", 20, x: 2, rest: 20), b("retour au calme", m(5))]),
        // Autre
        Workout(id: "other-b1", kind: .other, level: .beginner, title: "Séance douce 20 min",
                blocks: [b("échauffement", m(5)), b("activité", m(10)), b("retour au calme", m(5))]),
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
