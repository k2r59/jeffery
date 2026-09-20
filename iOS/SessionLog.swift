import Foundation

enum Feeling: String, Codable, CaseIterable, Identifiable {
    case easy, good, intense
    var id: String { rawValue }
    var label: String {
        switch self {
        case .easy: return "Facile"
        case .good: return "Bien"
        case .intense: return "Intense"
        }
    }
    var icon: String {
        switch self {
        case .easy: return "ressenti-facile"
        case .good: return "ressenti-bien"
        case .intense: return "ressenti-intense"
        }
    }
    var coachLabel: String {
        switch self {
        case .easy: return "facile"
        case .good: return "bien, dans le bon effort"
        case .intense: return "intense, dur à finir"
        }
    }
}

/// Bilan d'une séance coachée, gardé en local pour que Jeffrey s'en souvienne la fois suivante.
struct SessionSummary: Codable, Identifiable {
    var id: String
    var date: Date
    var kind: WorkoutKind
    var elapsed: TimeInterval
    var distance: Double?
    var averageHeartRate: Double?
    var maxHeartRate: Double?
    var feeling: Feeling?
    var goalLabel: String?
    var goalReached: Bool?
    var lastCoachLine: String?
    var zoneCounts: [Int]? = nil
    var analysis: String? = nil
    var advice: String? = nil
    var caution: String? = nil
    var transcriptExcerpt: [String]? = nil
    var memoryUpdated: Bool? = nil
    var walkingSeconds: TimeInterval? = nil
    var runningSeconds: TimeInterval? = nil
    var stationarySeconds: TimeInterval? = nil
    var ascent: Double? = nil
    var descent: Double? = nil
    var climbingSeconds: TimeInterval? = nil

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sessions.json")
    }

    static func loadAll() -> [SessionSummary] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        if let list = try? d.decode([SessionSummary].self, from: data) { return list }
        // Fichier illisible : on le met de côté au lieu de l'écraser.
        try? FileManager.default.moveItem(at: fileURL, to: fileURL.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))"))
        return []
    }

    /// Séance coachée correspondant à une séance Santé : recouvrement des périodes.
    static func matching(start: Date, end: Date? = nil, in list: [SessionSummary]? = nil) -> SessionSummary? {
        let all = list ?? loadAll()
        let healthEnd = end ?? start.addingTimeInterval(3600)
        return all.first { s in
            let sEnd = s.date.addingTimeInterval(s.elapsed)
            return s.date < healthEnd && sEnd > start && (abs(s.date.timeIntervalSince(start)) < 1800 || abs(sEnd.timeIntervalSince(healthEnd)) < 1800)
        }
    }

    static func upsert(_ s: SessionSummary) {
        var all = loadAll().filter { $0.id != s.id }
        all.append(s)
        all.sort { $0.date > $1.date }
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(Array(all.prefix(200))) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Phrase pour le prompt : la dernière séance et son ressenti.
    /// Une séance « de référence » dure au moins 20 min : les tours d'essai et les départs ratés ne comptent pas.
    static let referenceMinimumSeconds: TimeInterval = 20 * 60

    static func recapForCoach() -> String? {
        guard let last = loadAll().first(where: { $0.elapsed >= referenceMinimumSeconds }) ?? loadAll().first else { return nil }
        let days = Calendar.current.dateComponents([.day], from: last.date, to: Date()).day ?? 0
        var parts = ["\(last.kind.coachLabel) il y a \(days) jour\(days > 1 ? "s" : "")", Formatters.elapsed(last.elapsed)]
        if let d = last.distance { parts.append(Formatters.distance(d)) }
        if let hr = last.averageHeartRate { parts.append("FC moyenne \(Int(hr))") }
        if let g = last.goalLabel { parts.append("objectif \(g) \(last.goalReached == true ? "atteint" : "non atteint")") }
        if let f = last.feeling { parts.append("ressenti : \(f.coachLabel)") }
        var text = parts.joined(separator: ", ")
        if let a = last.advice, !a.isEmpty { text += ". Ton conseil d'alors pour aujourd'hui : « \(a) »" }
        return text
    }
}
