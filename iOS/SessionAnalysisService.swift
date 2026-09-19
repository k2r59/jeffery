import Foundation
import Combine

/// Lance le bilan et la mise à jour de la mémoire hors de toute vue : la tâche survit à la fermeture de l'écran de fin.
@MainActor
final class SessionAnalysisService: ObservableObject {
    static let shared = SessionAnalysisService()

    @Published private(set) var runningFor: String?          // id de la séance en cours d'analyse
    @Published private(set) var lastError: String?
    @Published private(set) var lastSource: String?
    @Published private(set) var version = 0                  // incrémenté à chaque résultat, pour rafraîchir les vues

    private var task: Task<Void, Never>?

    func analyze(_ input: SessionSummary, force: Bool = false) {
        var summary = input
        if !force, summary.analysis != nil, summary.memoryUpdated == true { return }
        if runningFor == summary.id { return }
        runningFor = summary.id
        lastError = nil
        task = Task {
            defer { runningFor = nil; version += 1 }
            let config = CoachConfig.load()
            let userName = config.userName
            let model = UserDefaults.standard.string(forKey: Prefs.analysisModel) ?? "gpt-5-mini"
            let provider = UserDefaults.standard.string(forKey: Prefs.analysisProvider) ?? "apple"
            let health = await SessionAnalyst.healthContext()
            let dossier = SessionAnalyst.dossier(summary: summary, config: config, health: health, zones: summary.zoneCounts ?? [])

            if summary.analysis == nil || force {
                do {
                    var result: SessionAnalyst.Result?
                    if provider == "apple" {
                        do {
                            let (apple, backend) = try await AppleAnalyst.analyze(dossier: dossier, userName: userName)
                            result = apple
                            lastSource = backend.label
                        } catch {
                            lastSource = nil
                        }
                    }
                    if result == nil {
                        guard await OpenAIAccess.isConfigured else { throw NSError(domain: "Analysis", code: 1, userInfo: [NSLocalizedDescriptionKey: "ni compte Jeffrey ni clé API, et modèles Apple indisponibles"]) }
                        result = try await SessionAnalyst.analyze(dossier: dossier, model: model, userName: userName)
                        lastSource = "OpenAI \(model)"
                    }
                    if let r = result, !r.analysis.trimmingCharacters(in: .whitespaces).isEmpty {
                        // On relit le disque : le ressenti a pu être choisi pendant l'analyse.
                        if let fresh = SessionSummary.loadAll().first(where: { $0.id == summary.id }) { summary = fresh }
                        summary.analysis = r.analysis
                        summary.advice = r.advice
                        summary.caution = r.caution
                        SessionSummary.upsert(summary)
                    } else {
                        throw NSError(domain: "Analysis", code: 2, userInfo: [NSLocalizedDescriptionKey: "réponse vide"])
                    }
                } catch {
                    lastError = error.localizedDescription
                    return
                }
            }

            // Mémoire longue, seulement si la personne a parlé pendant la séance.
            if summary.memoryUpdated != true, let lines = summary.transcriptExcerpt, lines.contains(where: { $0.hasPrefix("Lui :") }) {
                let memory = JeffreyMemory.shared
                let line = "\(summary.kind.coachLabel), \(Formatters.elapsed(summary.elapsed))\(summary.feeling.map { ", ressenti \($0.coachLabel)" } ?? "")"
                var notes: [String]?
                if provider == "apple", let (n, _) = try? await AppleAnalyst.updateMemory(transcript: lines, existing: memory.notes.map(\.text), summaryLine: line) {
                    notes = n
                } else if await OpenAIAccess.isConfigured {
                    notes = try? await SessionAnalyst.updateMemory(transcript: lines, existing: memory.notes.map(\.text), summaryLine: line, model: model)
                }
                if let notes {
                    memory.replace(with: notes)
                    if let fresh = SessionSummary.loadAll().first(where: { $0.id == summary.id }) { summary = fresh }
                    summary.memoryUpdated = true
                    SessionSummary.upsert(summary)
                }
            }
        }
    }

    /// Rattrape les séances passées restées sans bilan (au lancement de l'app).
    func catchUp() {
        guard runningFor == nil else { return }
        if let pending = SessionSummary.loadAll().first(where: { $0.analysis == nil && $0.elapsed >= 120 }) {
            analyze(pending)
        }
    }
}
