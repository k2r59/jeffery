import Foundation
import Combine

/// Mémoire longue de Jeffrey : notes durables sur la personne, lisibles et modifiables dans l'onglet Toi.
struct MemoryNote: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var text: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

@MainActor
final class JeffreyMemory: ObservableObject {
    static let shared = JeffreyMemory()
    static let maxNotes = 30

    @Published private(set) var notes: [MemoryNote] = []

    private var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("memory.json")
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        notes = (try? d.decode([MemoryNote].self, from: data)) ?? []
    }

    private func save() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(notes) { try? data.write(to: url, options: .atomic) }
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        notes.insert(MemoryNote(text: t), at: 0)
        trim()
        save()
    }

    func remove(_ id: String) {
        notes.removeAll { $0.id == id }
        save()
    }

    /// Remplace la liste par la version fusionnée renvoyée par le modèle (on conserve les dates des notes inchangées).
    func replace(with texts: [String]) {
        var result: [MemoryNote] = []
        for t in texts {
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            if let existing = notes.first(where: { $0.text == clean }) {
                result.append(existing)
            } else {
                result.append(MemoryNote(text: clean))
            }
        }
        notes = result
        trim()
        save()
    }

    private func trim() {
        if notes.count > Self.maxNotes { notes = Array(notes.prefix(Self.maxNotes)) }
    }

    /// Texte compact pour les prompts (voix et bilan).
    nonisolated static func promptText() -> String? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("memory.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        guard let notes = try? d.decode([MemoryNote].self, from: data), !notes.isEmpty else { return nil }
        let f = DateFormatter(); f.dateFormat = "d MMM"; f.locale = Locale(identifier: "fr_FR")
        return notes.map { "- (\(f.string(from: $0.updatedAt))) \($0.text)" }.joined(separator: "\n")
    }
}
