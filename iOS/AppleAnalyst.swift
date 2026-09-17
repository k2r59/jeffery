import Foundation
import FoundationModels

/// Intelligence Apple (Foundation Models, iOS 27) : d'abord le modèle serveur sur Private Cloud Compute
/// (32K de contexte, raisonnement), sinon le modèle local de l'iPhone. Aucune clé, aucun coût, rien ne quitte
/// l'écosystème Apple. OpenAI reste le secours quand Apple n'est pas disponible ou que le quota du jour est atteint.
enum AppleAnalyst {
    enum Backend: String { case privateCloud, onDevice
        var label: String { self == .privateCloud ? "Apple Private Cloud Compute" : "Modèle Apple sur l'iPhone" }
    }

    // MARK: Structures générées (le modèle renvoie exactement ces formes)

    @Generable(description: "Bilan écrit d'une séance de sport par un coach, en français, tutoiement")
    struct Bilan {
        @Guide(description: "3 à 5 phrases sur la séance du jour et la tendance par rapport au niveau, à l'intention et à l'historique")
        var analysis: String
        @Guide(description: "1 à 2 phrases : un conseil précis pour la prochaine séance (type, durée, intensité, récupération)")
        var advice: String
        @Guide(description: "Une phrase de prudence si un signal est inhabituel (FC max très élevée, FC de repos en hausse, ressenti intense répété), sinon vide")
        var caution: String
    }

    @Generable(description: "Notes durables d'un coach sur la personne qu'il accompagne")
    struct Notes {
        @Guide(description: "Liste fusionnée et à jour, au plus 30 notes de 120 caractères, faits durables uniquement (gênes, contexte, objectifs à moyen terme, préférences), à la troisième personne, en français")
        var notes: [String]
    }

    @Generable(description: "Objectif de séance compris à partir d'une phrase libre")
    struct ParsedGoal {
        @Guide(description: "duration si l'objectif est un temps, distance si c'est une distance, free si aucun chiffre", .anyOf(["duration", "distance", "free"]))
        var kind: String
        @Guide(description: "Minutes si kind=duration, kilomètres si kind=distance, 0 si free")
        var value: Double
        @Guide(description: "Précision d'intention en quelques mots (tranquille, fractionné, fatigué…), vide sinon")
        var note: String
    }

    static let coachInstructions = """
    Tu es Jeffrey, coach sportif. Tu rédiges le bilan écrit d'une séance à partir d'un dossier factuel. En français, tutoiement, \
    ton chaleureux et concret, jamais moralisateur. Tu compares la séance au niveau, à l'intention et à l'historique de la personne, \
    pas à des standards abstraits. Tu ne poses aucun diagnostic médical ; si un signal est inhabituel, tu le dis simplement et tu \
    conseilles de lever le pied ou d'en parler à un médecin.
    """

    // MARK: Disponibilité

    /// Le backend Apple utilisable maintenant. `preferLocal` : tâches courtes (objectif dicté) où la latence prime.
    /// Sur simulateur, le framework plante (assertion interne) dès qu'on interroge le modèle serveur : on ne tente rien.
    static var frameworkUsable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    static func availableBackend(preferLocal: Bool = false) -> Backend? {
        guard frameworkUsable else { return nil }
        let local = SystemLanguageModel.default.isAvailable
        if preferLocal, local { return .onDevice }
        let pcc = PrivateCloudComputeLanguageModel()
        if pcc.isAvailable, !pcc.quotaUsage.isLimitReached { return .privateCloud }
        if local { return .onDevice }
        return nil
    }

    static func availabilityDescription() -> String {
        guard frameworkUsable else { return "Intelligence Apple indisponible sur simulateur" }
        let pcc = PrivateCloudComputeLanguageModel()
        let local = SystemLanguageModel.default.availability
        var parts: [String] = []
        switch pcc.availability {
        case .available:
            if pcc.quotaUsage.isLimitReached {
                let reset = pcc.quotaUsage.resetDate.map { " (retour \($0.formatted(date: .omitted, time: .shortened)))" } ?? ""
                parts.append("Cloud privé Apple : quota du jour atteint\(reset)")
            } else {
                parts.append("Cloud privé Apple : disponible")
            }
        case .unavailable(let reason):
            parts.append("Cloud privé Apple : indisponible (\(describe(reason)))")
        }
        switch local {
        case .available: parts.append("Modèle Apple local : disponible")
        case .unavailable(let reason): parts.append("Modèle Apple local : indisponible (\(describeLocal(reason)))")
        }
        return parts.joined(separator: " · ")
    }

    private static func describe(_ r: PrivateCloudComputeLanguageModel.Availability.UnavailableReason) -> String {
        switch r {
        case .deviceNotEligible: return "appareil non compatible"
        case .systemNotReady: return "système pas prêt"
        @unknown default: return "entitlement ou Apple Intelligence manquant"
        }
    }

    private static func describeLocal(_ r: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch r {
        case .deviceNotEligible: return "appareil non compatible"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence désactivé dans Réglages"
        case .modelNotReady: return "modèle en cours de téléchargement"
        @unknown default: return "indisponible"
        }
    }

    private static func session(_ backend: Backend, instructions: String) -> LanguageModelSession {
        switch backend {
        case .privateCloud: return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: instructions)
        case .onDevice: return LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        }
    }

    private static func unavailable() -> NSError {
        NSError(domain: "AppleAnalyst", code: 1, userInfo: [NSLocalizedDescriptionKey: availabilityDescription()])
    }

    // MARK: Bilan

    static func analyze(dossier: String, userName: String) async throws -> (SessionAnalyst.Result, Backend) {
        guard let backend = availableBackend() else { throw unavailable() }
        let prompt = "Prénom : \(userName.isEmpty ? "inconnu" : userName)\n\n\(dossier)\n\nRédige le bilan."
        let s = session(backend, instructions: coachInstructions)
        var options = ContextOptions()
        if backend == .privateCloud { options.reasoningLevel = .moderate }
        let bilan = try await s.respond(to: prompt, generating: Bilan.self, contextOptions: options).content
        let caution = bilan.caution.trimmingCharacters(in: .whitespacesAndNewlines)
        return (SessionAnalyst.Result(analysis: bilan.analysis, advice: bilan.advice, caution: caution.isEmpty ? nil : caution), backend)
    }

    // MARK: Mémoire longue

    static func updateMemory(transcript: [String], existing: [String], summaryLine: String) async throws -> ([String], Backend) {
        guard let backend = availableBackend() else { throw unavailable() }
        let instructions = """
        Tu tiens les notes durables d'un coach sportif sur la personne qu'il accompagne. À partir de la transcription d'une séance \
        et des notes existantes, renvoie la liste MISE À JOUR : faits utiles sur la durée (blessures ou gênes, contexte de vie, \
        objectifs à moyen terme, préférences, habitudes, contraintes), jamais les chiffres d'une séance. Fusionne les doublons, \
        mets à jour ce qui a changé, supprime le périmé. Si la transcription n'apprend rien de durable, renvoie les notes existantes telles quelles.
        """
        // Le modèle local n'a que 4K de contexte : on lui donne une transcription plus courte.
        let lines = backend == .onDevice ? Array(transcript.suffix(30)) : transcript
        let prompt = "NOTES EXISTANTES :\n" + (existing.isEmpty ? "(aucune)" : existing.map { "- \($0)" }.joined(separator: "\n"))
            + "\n\nSÉANCE : \(summaryLine)\n\nTRANSCRIPTION :\n" + lines.joined(separator: "\n")
        let notes = try await session(backend, instructions: instructions).respond(to: prompt, generating: Notes.self).content.notes
        return (Array(notes.prefix(JeffreyMemory.maxNotes)), backend)
    }

    // MARK: Objectif dicté

    static func parseGoal(_ text: String, kind: WorkoutKind) async throws -> SessionGoal {
        guard let backend = availableBackend(preferLocal: true) else { throw unavailable() }
        let instructions = "Tu transformes une phrase libre d'un sportif en objectif de séance structuré. Sport : \(kind.coachLabel). Réponds strictement selon le schéma."
        let parsed = try await session(backend, instructions: instructions).respond(to: "Phrase : « \(text) »", generating: ParsedGoal.self).content
        switch parsed.kind {
        case "duration": return SessionGoal(kind: .duration, target: max(5, parsed.value) * 60, note: parsed.note)
        case "distance": return SessionGoal(kind: .distance, target: max(0.5, parsed.value) * 1000, note: parsed.note)
        default: return SessionGoal(kind: .free, target: 0, note: parsed.note)
        }
    }
}
