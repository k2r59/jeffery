import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.model) private var model: String = "gpt-realtime"
    @AppStorage(Prefs.voice) private var voice: String = "marin"
    @AppStorage(Prefs.maxHR) private var maxHR: Double = 0
    @AppStorage(Prefs.age) private var age: Int = 40
    @AppStorage(Prefs.goal) private var goal: String = ""
    @AppStorage(Prefs.cueInterval) private var cueInterval: Double = 60
    @AppStorage(Prefs.metricsInterval) private var metricsInterval: Double = 15
    @AppStorage(Prefs.autoCues) private var autoCues: Bool = true
    @AppStorage(Prefs.weightKg) private var weightKg: Double = 0
    @AppStorage(Prefs.heightCm) private var heightCm: Double = 0
    @State private var healthNotice: String?
    @AppStorage(Prefs.level) private var level: String = AthleteLevel.amateur.rawValue
    @AppStorage(Prefs.athleteNotes) private var athleteNotes: String = ""
    @AppStorage(Prefs.basePrompt) private var basePrompt: String = Prefs.defaultBasePrompt
    @State private var apiKey: String = KeychainStore.read(KeychainStore.apiKeyAccount) ?? ""
    @State private var saveNotice: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenAI") {
                    TextField("Clé API (sk-…)", text: $apiKey, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(3...8)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                    HStack {
                        Button {
                            if let pasted = UIPasteboard.general.string {
                                apiKey = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Label("Coller depuis le presse-papiers", systemImage: "doc.on.clipboard")
                        }
                        Spacer()
                        Text("\(apiKey.count) car.")
                            .font(.caption).foregroundStyle(apiKey.hasPrefix("sk-") ? .green : .orange)
                    }
                    TextField("Modèle", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Voix", selection: $voice) {
                        ForEach(Prefs.voices, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("Toi") {
                    Button {
                        Task {
                            let r = await HealthProfile.fetch()
                            if let a = r.age { age = a }
                            if let h = r.heightCm { heightCm = h }
                            if let w = r.weightKg { weightKg = w }
                            healthNotice = (r.age == nil && r.heightCm == nil && r.weightKg == nil)
                                ? "Rien trouvé dans Santé (autorisation refusée ou données absentes)."
                                : "Récupéré depuis Santé."
                        }
                    } label: {
                        Label("Récupérer depuis l'app Santé", systemImage: "heart.text.square")
                    }
                    if let healthNotice { Text(healthNotice).font(.caption).foregroundStyle(.secondary) }
                    Stepper("Âge : \(age) ans", value: $age, in: 10...100)
                    HStack {
                        Text("Poids")
                        Spacer()
                        TextField("kg", value: $weightKg, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100)
                        Text("kg").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Taille")
                        Spacer()
                        TextField("cm", value: $heightCm, format: .number.precision(.fractionLength(0)))
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 100)
                        Text("cm").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("FC max")
                        Spacer()
                        TextField("auto (220 − âge)", value: $maxHR, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                        Text("bpm").foregroundStyle(.secondary)
                    }
                    Text("Laisse 0 pour estimer automatiquement (\(220 - age) bpm).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Coach") {
                    Picker("Niveau", selection: $level) {
                        ForEach(AthleteLevel.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    TextField("À propos de toi : forme du jour, blessures, contexte…", text: $athleteNotes, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Prompt de base du coach", text: $basePrompt, axis: .vertical)
                        .font(.footnote)
                        .lineLimit(5...14)
                    Button("Rétablir le prompt par défaut") { basePrompt = Prefs.defaultBasePrompt }
                        .font(.footnote)
                }
                Section("Séance") {
                    TextField("Objectif (ex. 45 min en zone 2, ou 6 × 400 m)", text: $goal, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("Interventions automatiques du coach", isOn: $autoCues)
                    Stepper("Toutes les \(Int(cueInterval)) s", value: $cueInterval, in: 20...300, step: 10)
                        .disabled(!autoCues)
                    Stepper("Métriques envoyées toutes les \(Int(metricsInterval)) s", value: $metricsInterval, in: 5...60, step: 5)
                }
                Section {
                    Text(apiKey.isEmpty ? "Aucune clé enregistrée." : "Clé enregistrée : \(apiKey.prefix(7))…\(apiKey.suffix(4)), \(apiKey.count) caractères.")
                        .font(.caption).foregroundStyle(apiKey.isEmpty ? .red : .green)
                    if let saveNotice {
                        Text(saveNotice).font(.caption).foregroundStyle(.orange)
                    }
                    Text("La clé est stockée dans le trousseau de l'iPhone. L'audio et les métriques transitent uniquement vers l'API OpenAI.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Réglages")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        KeychainStore.write(apiKey, account: KeychainStore.apiKeyAccount)
                        if KeychainStore.lastError != errSecSuccess {
                            saveNotice = "Trousseau indisponible (\(KeychainStore.describe(KeychainStore.lastError))) : clé gardée en repli local."
                        }
                        apiKey = KeychainStore.read(KeychainStore.apiKeyAccount) ?? ""
                        if saveNotice == nil { dismiss() }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }
}
