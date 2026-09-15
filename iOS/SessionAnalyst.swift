import Foundation
import HealthKit

/// Bilan de fin de séance : appel texte (API Responses) avec profil, Santé, séance du jour et historique.
enum SessionAnalyst {
    struct Result: Codable {
        var analysis: String
        var advice: String
        var caution: String?
    }

    /// Indicateurs Santé utiles au bilan (lecture seule, valeurs récentes).
    struct HealthContext {
        var restingHR: Double?
        var vo2Max: Double?
        var hrv: Double?
        var last30DaysWorkouts: Int = 0
        var last30DaysMinutes: Double = 0
        var last30DaysKm: Double = 0
    }

    static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.restingHeartRate), HKQuantityType(.vo2Max), HKQuantityType(.heartRateVariabilitySDNN),
        HKObjectType.workoutType(),
    ]

    static func healthContext() async -> HealthContext {
        var ctx = HealthContext()
        guard HKHealthStore.isHealthDataAvailable() else { return ctx }
        let store = HKHealthStore()
        _ = try? await store.requestAuthorization(toShare: [], read: readTypes)
        ctx.restingHR = await latest(store, HKQuantityType(.restingHeartRate), .count().unitDivided(by: .minute()))
        ctx.vo2Max = await latest(store, HKQuantityType(.vo2Max), HKUnit(from: "ml/kg*min"))
        ctx.hrv = await latest(store, HKQuantityType(.heartRateVariabilitySDNN), .secondUnit(with: .milli))
        let start = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let workouts: [HKWorkout] = await withCheckedContinuation { c in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: HKQuery.predicateForSamples(withStart: start, end: nil, options: []),
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in c.resume(returning: (s as? [HKWorkout]) ?? []) }
            store.execute(q)
        }
        ctx.last30DaysWorkouts = workouts.count
        ctx.last30DaysMinutes = workouts.reduce(0) { $0 + $1.duration / 60 }
        ctx.last30DaysKm = workouts.compactMap(WorkoutHistory.distanceMeters).reduce(0, +) / 1000
        return ctx
    }

    private static func latest(_ store: HKHealthStore, _ type: HKQuantityType, _ unit: HKUnit) async -> Double? {
        await withCheckedContinuation { c in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, s, _ in
                c.resume(returning: (s?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }

    /// Dossier texte remis au modèle.
    static func dossier(summary: SessionSummary, config: CoachConfig, health: HealthContext, zones: [Int]) -> String {
        var lines: [String] = []
        var profile = ["niveau \(config.level.coachLabel)"]
        if config.age > 0 { profile.append("\(config.age) ans") }
        if config.weightKg > 0 { profile.append("\(Int(config.weightKg)) kg") }
        if config.heightCm > 0 { profile.append("\(Int(config.heightCm)) cm") }
        if let intent = Intent(rawValue: config.intent) { profile.append("intention : \(intent.coachLabel)") }
        lines.append("PROFIL : " + profile.joined(separator: ", ") + ". FC max estimée \(Int(config.maxHR)) bpm.")
        if !config.athleteNotes.isEmpty { lines.append("À propos de lui : \(config.athleteNotes)") }

        var h: [String] = []
        if let r = health.restingHR { h.append("FC repos \(Int(r)) bpm") }
        if let v = health.vo2Max { h.append(String(format: "VO2max %.1f", v)) }
        if let hrv = health.hrv { h.append("VFC \(Int(hrv)) ms") }
        h.append("30 derniers jours : \(health.last30DaysWorkouts) séances, \(Int(health.last30DaysMinutes)) min, \(String(format: "%.1f", health.last30DaysKm)) km")
        lines.append("SANTÉ : " + h.joined(separator: " · "))

        var s = ["\(summary.kind.coachLabel)", Formatters.elapsed(summary.elapsed)]
        if let d = summary.distance {
            s.append(Formatters.distance(d))
            if let p = Formatters.pace(speedMetersPerSecond: d / max(1, summary.elapsed)) { s.append("allure moyenne \(p)") }
        }
        if let a = summary.averageHeartRate { s.append("FC moyenne \(Int(a))") }
        if let m = summary.maxHeartRate { s.append("FC max \(Int(m))") }
        if zones.reduce(0, +) > 0 {
            let total = Double(zones.reduce(0, +))
            s.append("répartition zones Z1-Z5 : " + zones.map { "\(Int(Double($0) / total * 100)) %" }.joined(separator: " / "))
        }
        if let g = summary.goalLabel { s.append("objectif \(g) \(summary.goalReached == true ? "atteint" : "non atteint")") }
        if let f = summary.feeling { s.append("ressenti : \(f.coachLabel)") }
        lines.append("SÉANCE DU JOUR : " + s.joined(separator: " · "))

        let previous = SessionSummary.loadAll().filter { $0.id != summary.id }.prefix(8)
        if previous.isEmpty {
            lines.append("HISTORIQUE DANS L'APP : première séance coachée.")
        } else {
            lines.append("HISTORIQUE DANS L'APP (plus récent d'abord) :")
            for p in previous {
                let days = Calendar.current.dateComponents([.day], from: p.date, to: Date()).day ?? 0
                var row = ["J-\(days)", p.kind.coachLabel, Formatters.elapsed(p.elapsed)]
                if let d = p.distance { row.append(Formatters.distance(d)) }
                if let a = p.averageHeartRate { row.append("FC moy \(Int(a))") }
                if let f = p.feeling { row.append("ressenti \(f.coachLabel)") }
                if let g = p.goalLabel { row.append("objectif \(g) \(p.goalReached == true ? "ok" : "ko")") }
                lines.append("- " + row.joined(separator: " · "))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Appel texte, réponse JSON {analysis, advice, caution}.
    static func analyze(dossier: String, apiKey: String, model: String, userName: String) async throws -> Result {
        let system = """
        Tu es Jeffrey, coach sportif. Tu rédiges le bilan écrit d'une séance à partir d'un dossier factuel. En français, tutoiement, \
        ton chaleureux et concret, jamais moralisateur. Tu compares la séance au niveau, à l'intention et à l'historique de la personne, \
        pas à des standards abstraits. Tu ne poses aucun diagnostic médical ; si un signal est inhabituel (FC max très élevée pour l'âge, \
        FC de repos en hausse, ressenti intense répété), tu le dis simplement et tu conseilles de lever le pied ou d'en parler à un médecin. \
        Réponds UNIQUEMENT en JSON : {"analysis": "3 à 5 phrases sur la séance et la tendance", "advice": "1 à 2 phrases, un conseil précis \
        pour la prochaine séance (type, durée, intensité, récupération)", "caution": "phrase de prudence ou null"}.
        """
        let body: [String: Any] = [
            "model": model,
            "instructions": system,
            "input": "Prénom : \(userName.isEmpty ? "inconnu" : userName)\n\n\(dossier)",
            "max_output_tokens": 600,
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }.flatMap { $0["message"] as? String } ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw NSError(domain: "SessionAnalyst", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let text = outputText(from: data)
        guard let jsonStart = text.firstIndex(of: "{"), let jsonEnd = text.lastIndex(of: "}") else {
            return Result(analysis: text.trimmingCharacters(in: .whitespacesAndNewlines), advice: "", caution: nil)
        }
        let jsonData = Data(text[jsonStart...jsonEnd].utf8)
        if let r = try? JSONDecoder().decode(Result.self, from: jsonData) { return r }
        return Result(analysis: text, advice: "", caution: nil)
    }

    /// Concatène les segments texte d'une réponse Responses API.
    private static func outputText(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let t = json["output_text"] as? String { return t }
        var parts: [String] = []
        for item in json["output"] as? [[String: Any]] ?? [] {
            for content in item["content"] as? [[String: Any]] ?? [] where content["type"] as? String == "output_text" {
                if let t = content["text"] as? String { parts.append(t) }
            }
        }
        return parts.joined()
    }
}
