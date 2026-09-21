import Foundation

/// Objectif d'une séance : durée, distance ou libre, avec une note optionnelle (« tranquille », « viser 25 min »…).
struct SessionGoal: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case duration, distance, free
        var id: String { rawValue }
        var label: String {
            switch self {
            case .duration: return "Durée"
            case .distance: return "Distance"
            case .free: return "Libre"
            }
        }
        var icon: String {
            switch self {
            case .duration: return "chronometre"
            case .distance: return "distance"
            case .free: return "libre"
            }
        }
    }

    var kind: Kind
    var target: Double      // secondes ou mètres selon le type
    var note: String = ""

    static let free = SessionGoal(kind: .free, target: 0)

    /// Tour d'essai de l'onboarding : 2 minutes chez soi, Jeffrey se présente, on marche quelques pas, mini-bilan.
    static let trialNote = "tour d'essai"
    static let trial = SessionGoal(kind: .duration, target: 120, note: trialNote)
    var isTrial: Bool { note == Self.trialNote }

    var label: String {
        switch kind {
        case .duration: return "\(Int(target / 60)) min"
        case .distance: return Formatters.distance(target)
        case .free: return "Libre"
        }
    }

    func coachLabel() -> String {
        var s: String
        switch kind {
        case .duration: s = "tenir \(Int(target / 60)) minutes"
        case .distance: s = "faire \(Formatters.distance(target))"
        case .free: s = "sortie libre, sans objectif chiffré"
        }
        if !note.trimmingCharacters(in: .whitespaces).isEmpty { s += " (\(note))" }
        return s
    }

    /// Progression 0-1 et libellé « restantes ».
    func progress(elapsed: TimeInterval, distance: Double?) -> (fraction: Double, remaining: String?) {
        switch kind {
        case .duration:
            let rem = max(0, target - elapsed)
            return (min(1, elapsed / max(1, target)), Formatters.elapsed(rem) + " restantes")
        case .distance:
            let d = distance ?? 0
            let rem = max(0, target - d)
            return (min(1, d / max(1, target)), Formatters.distance(rem) + " restants")
        case .free:
            return (0, nil)
        }
    }

    func isReached(elapsed: TimeInterval, distance: Double?) -> Bool {
        switch kind {
        case .duration: return elapsed >= target
        case .distance: return (distance ?? 0) >= target
        case .free: return false
        }
    }
}

