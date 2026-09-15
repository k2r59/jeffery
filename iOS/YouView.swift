import SwiftUI

/// Onglet « Toi » : profil, forme du moment, ressentis récents.
struct YouView: View {
    @AppStorage(Prefs.userName) private var userName: String = ""
    @AppStorage(Prefs.intent) private var intentRaw: String = ""
    @AppStorage(Prefs.level) private var level: String = AthleteLevel.amateur.rawValue
    @AppStorage(Prefs.age) private var age: Int = 40
    @AppStorage(Prefs.weightKg) private var weightKg: Double = 0
    @AppStorage(Prefs.heightCm) private var heightCm: Double = 0
    @AppStorage(Prefs.maxHR) private var maxHR: Double = 0
    @AppStorage(Prefs.athleteNotes) private var athleteNotes: String = ""
    @State private var health: SessionAnalyst.HealthContext?
    @ObservedObject private var memory = JeffreyMemory.shared
    @State private var newNote = ""
    @State private var loadingHealth = false
    @State private var healthNotice: String?
    @FocusState private var focused: Bool

    private var summaries: [SessionSummary] { SessionSummary.loadAll() }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        JeffreyHeader()
                        Text(userName.isEmpty ? "Toi." : "\(userName).").font(.display(30, weight: .black)).foregroundStyle(.white)
                        Text("Ce que Jeffrey sait de toi pour s'adapter.").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)

                        section("Profil") {
                            ProfilePhotoPicker(name: userName)
                            field("Prénom", text: $userName)
                            HStack(spacing: 8) {
                                ForEach(Intent.allCases) { i in
                                    chip(i.label, icon: i.icon, selected: intentRaw == i.rawValue) {
                                        intentRaw = i.rawValue
                                        level = i.level.rawValue
                                    }
                                }
                            }
                            HStack(spacing: 4) {
                                ForEach(AthleteLevel.allCases) { l in
                                    segment(l.label, selected: level == l.rawValue) { level = l.rawValue }
                                }
                            }
                            .padding(4).background(Capsule().fill(Theme.surfaceRaised))
                        }

                        section("Mesures") {
                            HStack(spacing: 10) {
                                measure("Âge", value: "\(age)", unit: "ans")
                                measure("Poids", value: weightKg > 0 ? String(format: "%.0f", weightKg) : "--", unit: "kg")
                                measure("Taille", value: heightCm > 0 ? "\(Int(heightCm))" : "--", unit: "cm")
                                measure("FC max", value: "\(maxHR > 0 ? Int(maxHR) : 220 - age)", unit: "bpm")
                            }
                            Button {
                                Task {
                                    let r = await HealthProfile.fetch()
                                    if let a = r.age { age = a }
                                    if let h = r.heightCm { heightCm = h }
                                    if let w = r.weightKg { weightKg = w }
                                    healthNotice = (r.age == nil && r.weightKg == nil && r.heightCm == nil) ? "Rien trouvé dans Santé." : "Mis à jour depuis Santé."
                                }
                            } label: {
                                HStack(spacing: 8) { JIcon("frequence-cardiaque", size: 16); Text("Mettre à jour depuis Santé") }
                                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.creme)
                                    .frame(maxWidth: .infinity).frame(height: 42)
                                    .background(Capsule().fill(Theme.surfaceRaised))
                            }
                            if let healthNotice { Text(healthNotice).font(.caption).foregroundStyle(Theme.muted) }
                            HStack {
                                Stepper("Âge \(age)", value: $age, in: 10...100).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.creme)
                            }
                            HStack(spacing: 10) {
                                numberField("Poids (kg)", value: $weightKg)
                                numberField("Taille (cm)", value: $heightCm)
                                numberField("FC max", value: $maxHR)
                            }
                        }

                        section("Ta forme") {
                            if let h = health {
                                HStack(spacing: 10) {
                                    measure("FC repos", value: h.restingHR.map { "\(Int($0))" } ?? "--", unit: "bpm")
                                    measure("VO2max", value: h.vo2Max.map { String(format: "%.0f", $0) } ?? "--", unit: "ml/kg/min")
                                    measure("VFC", value: h.hrv.map { "\(Int($0))" } ?? "--", unit: "ms")
                                }
                                Text("30 derniers jours : \(h.last30DaysWorkouts) séances · \(Int(h.last30DaysMinutes)) min · \(String(format: "%.1f", h.last30DaysKm)) km, toutes apps confondues")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                            } else {
                                Text(loadingHealth ? "Lecture de Santé…" : "Données Santé indisponibles.").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                            }
                        }

                        section("À propos de toi") {
                            TextField("Forme du jour, blessures, contraintes, ce que Jeffrey doit savoir…", text: $athleteNotes, axis: .vertical)
                                .lineLimit(2...5).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.creme)
                                .focused($focused)
                        }

                        section("Ce que Jeffrey retient de toi") {
                            if memory.notes.isEmpty {
                                Text("Rien encore. Après chaque séance, Jeffrey note ce qui compte sur la durée : une gêne, un objectif, une préférence. Tu peux aussi lui écrire directement.")
                                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                            }
                            ForEach(memory.notes) { note in
                                HStack(alignment: .top, spacing: 10) {
                                    JeffreyMark(size: 16).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(note.text).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.creme)
                                        Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                    Button { memory.remove(note.id) } label: { JIcon("fermer", size: 14).foregroundStyle(Theme.muted) }
                                }
                            }
                            HStack(spacing: 8) {
                                TextField("Dis-lui quelque chose à retenir…", text: $newNote)
                                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.creme)
                                    .padding(.horizontal, 12).frame(height: 40)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceRaised))
                                    .onSubmit { memory.add(newNote); newNote = "" }
                                Button {
                                    memory.add(newNote); newNote = ""
                                } label: {
                                    JIcon("valider", size: 16).foregroundStyle(Theme.background)
                                        .frame(width: 40, height: 40).background(Circle().fill(Theme.citron))
                                }
                                .disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }

                        if !summaries.isEmpty {
                            section("Tes derniers ressentis") {
                                ForEach(summaries.prefix(6)) { s in
                                    HStack(spacing: 10) {
                                        JIcon(s.feeling?.icon ?? "libre", size: 18).foregroundStyle(s.feeling == nil ? Theme.muted : Theme.citron)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(s.kind.label) · \(Formatters.elapsed(s.elapsed))\(s.distance.map { " · \(Formatters.distance($0))" } ?? "")")
                                                .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.creme)
                                            Text("\(s.date.formatted(date: .abbreviated, time: .omitted))\(s.feeling.map { " · \($0.label)" } ?? "")\(s.goalLabel.map { " · objectif \($0)\(s.goalReached == true ? " ✓" : "")" } ?? "")")
                                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                                        }
                                        Spacer()
                                    }
                                }
                            }
                        }
                    }
                    .padding(18)
                    .padding(.bottom, 70)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                loadingHealth = true
                health = await SessionAnalyst.healthContext()
                loadingHealth = false
            }
        }
    }

    // MARK: Composants

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
            content()
        }
        .card()
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.creme)
            .padding(.horizontal, 14).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surfaceRaised))
    }

    private func numberField(_ placeholder: String, value: Binding<Double>) -> some View {
        TextField(placeholder, value: value, format: .number.precision(.fractionLength(0)))
            .keyboardType(.decimalPad)
            .font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.creme)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceRaised))
    }

    private func measure(_ title: String, value: String, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.display(20, weight: .black).monospacedDigit()).foregroundStyle(Theme.creme).lineLimit(1).minimumScaleFactor(0.6)
            Text(unit).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
            Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func chip(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                JIcon(icon, size: 16)
                Text(title).font(.system(size: 10, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(selected ? Theme.background : Theme.creme)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Theme.citron : Theme.surfaceRaised))
        }
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .bold))
                .foregroundStyle(selected ? Theme.background : Theme.creme)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(Capsule().fill(selected ? Theme.citron : .clear))
        }
    }
}
