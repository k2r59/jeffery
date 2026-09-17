import Foundation
import FoundationModels

/// Bilan de fin de séance par les modèles Apple (Foundation Models, iOS 27) :
/// d'abord le modèle serveur sur Private Cloud Compute (32K, raisonnement), sinon le modèle local de l'iPhone.
/// Rien ne quitte l'écosystème Apple ; aucune clé, aucun coût. OpenAI reste le secours quand Apple n'est pas disponible.
enum AppleAnalyst {
    enum Backend: String { case privateCloud, onDevice }

    @Generable(description: "Bilan écrit d'une séance de sport par un coach, en français, tutoiement")
    struct Bilan {
        @Guide(description: "3 à 5 phrases sur la séance du jour et la tendance par rapport au niveau, à l'intention et à l'historique")
        var analysis: String
        @Guide(description: "1 à 2 phrases : un conseil précis pour la prochaine séance (type, durée, intensité, récupération)")
        var advice: String
        @Guide(description: "Une phrase de prudence si un signal est inhabituel (FC max très élevée, FC de repos en hausse, ressenti intense répété), sinon vide")
        var caution: String
    }

    static let instructions = """
    Tu es Jeffrey, coach sportif. Tu rédiges le bilan écrit d'une séance à partir d'un dossier factuel. En français, tutoiement, \
    ton chaleureux et concret, jamais moralisateur. Tu compares la séance au niveau, à l'intention et à l'historique de la personne, \
    pas à des standards abstraits. Tu ne poses aucun diagnostic médical ; si un signal est inhabituel, tu le dis simplement et tu \
    conseilles de lever le pied ou d'en parler à un médecin.
    """

    /// Le backend Apple utilisable en ce moment, ou nil.
    static func availableBackend() -> Backend? {
        if PrivateCloudComputeLanguageModel().isAvailable { return .privateCloud }
        if SystemLanguageModel.default.isAvailable { return .onDevice }
        return nil
    }

    static func availabilityDescription() -> String {
        let pcc = PrivateCloudComputeLanguageModel()
        switch pcc.availability {
        case .available: return "Apple Private Cloud Compute disponible"
        case .unavailable(let reason):
            switch SystemLanguageModel.default.availability {
            case .available: return "Modèle Apple local disponible (cloud Apple : \(reason))"
            case .unavailable(let r2): return "Modèles Apple indisponibles (cloud : \(reason) ; local : \(r2))"
            }
        }
    }

    /// Lance le bilan sur le meilleur backend Apple disponible ; lève une erreur si aucun.
    static func analyze(dossier: String, userName: String) async throws -> (SessionAnalyst.Result, Backend) {
        guard let backend = availableBackend() else {
            throw NSError(domain: "AppleAnalyst", code: 1, userInfo: [NSLocalizedDescriptionKey: availabilityDescription()])
        }
        let prompt = "Prénom : \(userName.isEmpty ? "inconnu" : userName)\n\n\(dossier)\n\nRédige le bilan."
        let bilan: Bilan
        switch backend {
        case .privateCloud:
            let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: instructions)
            var options = ContextOptions()
            options.reasoningLevel = .light
            bilan = try await session.respond(to: prompt, generating: Bilan.self, contextOptions: options).content
        case .onDevice:
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            bilan = try await session.respond(to: prompt, generating: Bilan.self).content
        }
        let caution = bilan.caution.trimmingCharacters(in: .whitespacesAndNewlines)
        return (SessionAnalyst.Result(analysis: bilan.analysis, advice: bilan.advice, caution: caution.isEmpty ? nil : caution), backend)
    }
}
