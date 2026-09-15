import Foundation

/// Réglages persistés dans UserDefaults (la clé API est dans le trousseau).
enum Prefs {
    static let model = "pref.model"
    static let voice = "pref.voice"
    static let maxHR = "pref.maxHR"
    static let age = "pref.age"
    static let goal = "pref.goal"
    static let cueInterval = "pref.cueInterval"
    static let metricsInterval = "pref.metricsInterval"
    static let autoCues = "pref.autoCues"
    static let kind = "pref.kind"
    static let mode = "pref.mode"
    static let level = "pref.level"
    static let athleteNotes = "pref.athleteNotes"
    static let basePrompt = "pref.basePrompt"

    static let defaultBasePrompt = """
    Tu es un coach sportif vocal, présent en direct pendant la séance, en français, et tu tutoies.
    Tu t'adaptes au sportif : son niveau (débutant, amateur ou confirmé), son état de forme du jour, \
    ses contraintes éventuelles. Un débutant a besoin de repères simples, de pauses et de réassurance ; \
    un confirmé attend des consignes précises sur l'allure, les zones et la gestion de l'effort.
    Tu encourages sincèrement, sans flatterie creuse. Si l'objectif n'est pas atteint, si la personne ralentit, \
    s'arrête ou abandonne un bloc, tu ne juges jamais : tu valorises ce qui a été fait, tu proposes une \
    adaptation réaliste et tu gardes la motivation intacte pour la suite. Tu rappelles la sécurité si \
    la fréquence cardiaque reste très haute ou si la personne décrit une douleur inhabituelle.
    """

    static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            model: "gpt-realtime",
            voice: "marin",
            maxHR: 0,
            age: 40,
            goal: "",
            cueInterval: 60.0,
            metricsInterval: 15.0,
            autoCues: true,
            kind: WorkoutKind.running.rawValue,
            mode: CaptureMode.companion.rawValue,
            level: AthleteLevel.amateur.rawValue,
            athleteNotes: "",
            basePrompt: defaultBasePrompt,
        ])
    }
}

enum AthleteLevel: String, CaseIterable, Identifiable {
    case beginner, amateur, confirmed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .beginner: return "Débutant"
        case .amateur: return "Amateur"
        case .confirmed: return "Confirmé"
        }
    }
    var coachLabel: String {
        switch self {
        case .beginner: return "débutant (reprise ou peu d'expérience)"
        case .amateur: return "amateur régulier"
        case .confirmed: return "confirmé (entraînement structuré)"
        }
    }
}

struct CoachConfig {
    var apiKey: String
    var level: AthleteLevel
    var athleteNotes: String
    var basePrompt: String
    var model: String
    var voice: String
    var maxHR: Double
    var goal: String
    var cueInterval: TimeInterval
    var metricsInterval: TimeInterval
    var autoCues: Bool

    /// En Debug (simulateur), une clé passée en variable d'environnement OPENAI_API_KEY est copiée dans le trousseau
    /// au premier lancement : `SIMCTL_CHILD_OPENAI_API_KEY=… xcrun simctl launch <udid> dev.promo.watchcoach`.
    static func bootstrapKeyFromEnvironment() {
        #if DEBUG
        if (KeychainStore.read(KeychainStore.apiKeyAccount) ?? "").isEmpty,
           let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            KeychainStore.write(key, account: KeychainStore.apiKeyAccount)
        }
        #endif
    }

    static func load() -> CoachConfig {
        Prefs.registerDefaults()
        bootstrapKeyFromEnvironment()
        let d = UserDefaults.standard
        var maxHR = d.double(forKey: Prefs.maxHR)
        if maxHR <= 0 {
            let age = d.integer(forKey: Prefs.age)
            maxHR = Double(220 - max(10, min(100, age)))
        }
        let base = d.string(forKey: Prefs.basePrompt)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CoachConfig(
            apiKey: KeychainStore.read(KeychainStore.apiKeyAccount) ?? "",
            level: AthleteLevel(rawValue: d.string(forKey: Prefs.level) ?? "") ?? .amateur,
            athleteNotes: d.string(forKey: Prefs.athleteNotes) ?? "",
            basePrompt: base.isEmpty ? Prefs.defaultBasePrompt : base,
            model: d.string(forKey: Prefs.model) ?? "gpt-realtime",
            voice: d.string(forKey: Prefs.voice) ?? "marin",
            maxHR: maxHR,
            goal: d.string(forKey: Prefs.goal) ?? "",
            cueInterval: max(20, d.double(forKey: Prefs.cueInterval)),
            metricsInterval: max(5, d.double(forKey: Prefs.metricsInterval)),
            autoCues: d.bool(forKey: Prefs.autoCues)
        )
    }

    func instructions(kind: WorkoutKind, mode: CaptureMode) -> String {
        let goalLine = goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Aucun objectif précis n'a été donné : demande-le brièvement au début, puis adapte-toi."
            : "Objectif annoncé pour la séance : \(goal)."
        let notes = athleteNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesLine = notes.isEmpty ? "" : "\nCe que le sportif dit de lui : \(notes)"
        return """
        \(basePrompt)

        Sportif : niveau \(level.coachLabel).\(notesLine)
        Séance en cours : \(kind.coachLabel). Il porte une Apple Watch ; les données arrivent en \(mode.label). \(goalLine)

        Tu reçois régulièrement des messages système commençant par [MÉTRIQUES] : fréquence cardiaque, zone cardiaque, \
        distance, allure, calories, temps écoulé. Utilise-les pour coacher : intensité, respiration, rythme, encouragements, \
        rappels d'objectif, alerte si la fréquence cardiaque monte trop (zone 5 prolongée) ou si l'allure décroche.

        Règles :
        - Réponses très courtes : 1 à 3 phrases, orales, naturelles, sans liste ni formatage.
        - N'énumère pas les chiffres bêtement : interprète-les (« tu es en zone 4, c'est bien pour ce bloc, tiens 2 minutes »).
        - Ne répète pas la même consigne à chaque intervention ; varie et sois concret.
        - Si l'utilisateur pose une question, réponds directement.
        - Si les métriques sont absentes ou vieilles, dis-le simplement et continue à coacher au temps.
        - Zones cardiaques (FC max estimée \(Int(maxHR)) bpm) : Z1 < 60 %, Z2 60-70 %, Z3 70-80 %, Z4 80-90 %, Z5 > 90 %.
        """
    }
}
