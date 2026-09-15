import SwiftUI
import PhotosUI

/// Onglet « Toi » : profil, objectif personnel, niveau, mesures, Santé, forme, contexte, mémoire de Jeffrey.
struct YouView: View {
    @AppStorage(Prefs.userName) private var userName: String = ""
    @AppStorage(Prefs.intent) private var intentRaw: String = ""
    @AppStorage(Prefs.level) private var level: String = AthleteLevel.amateur.rawValue
    @AppStorage(Prefs.age) private var age: Int = 40
    @AppStorage(Prefs.weightKg) private var weightKg: Double = 0
    @AppStorage(Prefs.heightCm) private var heightCm: Double = 0
    @AppStorage(Prefs.maxHR) private var maxHR: Double = 0
    @AppStorage(Prefs.athleteNotes) private var athleteNotes: String = ""
    @ObservedObject private var memory = JeffreyMemory.shared
    @ObservedObject private var photos = ProfileImageStore.shared
    @State private var photoSelection: PhotosPickerItem?
    @State private var health: SessionAnalyst.HealthContext?
    @State private var loadingHealth = false
    @State private var healthNotice: String?
    @State private var editingMeasures = false
    @State private var editingName = false
    @State private var newNote = ""
    @FocusState private var notesFocused: Bool

    private var summaries: [SessionSummary] { SessionSummary.loadAll() }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        JeffreyWordmark(size: 32).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Toi").font(.display(30, weight: .black)).foregroundStyle(Theme.creme)
                            Text("Pour un coaching qui te ressemble.").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.muted)
                        }

                        profileCard
                        titled("Ton objectif personnel") { intentList }
                        titled("Ton niveau") { levelSegments }
                        titled("Tes mesures", trailing: AnyView(editButton)) { measuresGrid }
                        healthCard.id("sante")
                        fitnessCard
                        last30Card
                        aboutCard
                        memoryCard
                        if !summaries.isEmpty { feelingsCard }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .padding(.bottom, 70)
                }
                .scrollDismissesKeyboard(.interactively)
                .clipped()
                .onAppear {
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["WATCHCOACH_SCROLL"] == "sante" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { proxy.scrollTo("sante", anchor: .top) }
                    }
                    #endif
                }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await loadHealth() }
        }
    }

    // MARK: Profil

    private var profileCard: some View {
        HStack(spacing: 16) {
            ProfileAvatar(name: userName, size: 88)
            VStack(alignment: .leading, spacing: 8) {
                if editingName {
                    TextField("Ton prénom", text: $userName)
                        .font(.display(26, weight: .black)).foregroundStyle(Theme.creme)
                        .onSubmit { editingName = false }
                } else {
                    Button { editingName = true } label: {
                        Text(userName.isEmpty ? "Ton prénom" : userName)
                            .font(.display(26, weight: .black)).foregroundStyle(userName.isEmpty ? Theme.muted : Theme.creme)
                    }
                }
                PhotosPicker(selection: $photoSelection, matching: .images, photoLibrary: .shared()) {
                    HStack(spacing: 8) {
                        Image(systemName: "camera").font(.system(size: 15, weight: .semibold))
                        Text(photos.image == nil ? "Ajouter une photo" : "Modifier la photo")
                    }
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.creme)
                }
                if photos.image != nil {
                    Button { photos.clear() } label: { Text("Retirer la photo").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted) }
                }
            }
            Spacer()
        }
        .card()
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { photos.set(img) }
                photoSelection = nil
            }
        }
    }

    // MARK: Objectif personnel

    private var intentList: some View {
        VStack(spacing: 8) {
            intentRows
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
    }

    private var intentRows: some View {
        VStack(spacing: 8) {
            ForEach(Intent.allCases) { i in
                let selected = intentRaw == i.rawValue
                Button {
                    intentRaw = i.rawValue
                    level = i.level.rawValue
                } label: {
                    HStack(spacing: 12) {
                        JIcon(i.icon, size: 18).foregroundStyle(selected ? Theme.citron : Theme.creme)
                        Text(i.label).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.creme)
                        Spacer()
                        ZStack {
                            Circle().stroke(selected ? Theme.citron : Theme.muted, lineWidth: 2).frame(width: 22, height: 22)
                            if selected { Circle().fill(Theme.citron).frame(width: 12, height: 12) }
                        }
                    }
                    .padding(.horizontal, 14).frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Theme.citron.opacity(0.16) : Theme.surfaceRaised))
                }
            }
        }
    }

    private var levelSegments: some View {
        HStack(spacing: 0) {
            ForEach(AthleteLevel.allCases) { l in
                let selected = level == l.rawValue
                Button { level = l.rawValue } label: {
                    Text(l.label).font(.system(size: 14, weight: .bold))
                        .foregroundStyle(selected ? Theme.background : Theme.creme)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.citron : .clear))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceRaised))
    }

    // MARK: Mesures

    private var editButton: some View {
        Button { withAnimation(.snappy) { editingMeasures.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: editingMeasures ? "checkmark" : "pencil").font(.system(size: 13, weight: .bold))
                Text(editingMeasures ? "Terminé" : "Modifier")
            }
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.citron)
        }
    }

    private var measuresGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 10) {
            measureTile("person", "Âge", value: age > 0 ? "\(age)" : nil, unit: "ans") {
                HStack(spacing: 8) {
                    Button { age = max(10, age - 1) } label: { Image(systemName: "minus").font(.system(size: 12, weight: .black)).frame(width: 26, height: 26).background(Circle().fill(Theme.surfaceRaised)) }
                    Text("\(age)").font(.system(size: 18, weight: .bold).monospacedDigit())
                    Button { age = min(100, age + 1) } label: { Image(systemName: "plus").font(.system(size: 12, weight: .black)).frame(width: 26, height: 26).background(Circle().fill(Theme.surfaceRaised)) }
                }
                .foregroundStyle(Theme.creme)
            }
            measureTile("bag", "Poids", value: weightKg > 0 ? String(format: "%.0f", weightKg) : nil, unit: "kg") {
                numberField(value: $weightKg, unit: "kg")
            }
            measureTile("ruler", "Taille", value: heightCm > 0 ? "\(Int(heightCm))" : nil, unit: "cm") {
                numberField(value: $heightCm, unit: "cm")
            }
            measureTile("heart", "FC maximale", value: "\(maxHR > 0 ? Int(maxHR) : 220 - age)", unit: "bpm") {
                numberField(value: $maxHR, unit: "bpm")
            }
        }
    }

    private func measureTile<Editor: View>(_ icon: String, _ title: String, value: String?, unit: String, @ViewBuilder editor: () -> Editor) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 20, weight: .regular)).foregroundStyle(Theme.creme).frame(width: 26).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                if editingMeasures {
                    editor()
                } else if let value {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value).font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(Theme.creme)
                        Text(unit).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.creme)
                    }
                } else {
                    Text("À renseigner").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.creme)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14).frame(minHeight: 74)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
    }

    private func numberField(value: Binding<Double>, unit: String) -> some View {
        HStack(spacing: 4) {
            TextField("0", value: value, format: .number.precision(.fractionLength(0)))
                .keyboardType(.decimalPad)
                .font(.system(size: 18, weight: .bold).monospacedDigit()).foregroundStyle(Theme.creme)
                .frame(width: 48)
            Text(unit).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Santé

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "heart").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.creme)
                Text("Données Santé").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.creme)
            }
            Button {
                Task {
                    let r = await HealthProfile.fetch()
                    if let a = r.age { age = a }
                    if let h = r.heightCm { heightCm = h }
                    if let w = r.weightKg { weightKg = w }
                    await loadHealth()
                    healthNotice = (r.age == nil && r.weightKg == nil && r.heightCm == nil && health?.restingHR == nil) ? "Rien trouvé dans Santé." : "Mis à jour depuis Santé."
                }
            } label: {
                HStack(spacing: 8) { Image(systemName: "heart").font(.system(size: 15, weight: .semibold)); Text("Actualiser depuis Santé") }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.creme)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surfaceRaised))
            }
            if let healthNotice { Text(healthNotice).font(.caption).foregroundStyle(Theme.muted) }
        }
        .card()
    }

    private var fitnessCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ta forme").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.creme).padding(.bottom, 8)
            fitnessRow("Fréquence au repos", value: health?.restingHR.map { "\(Int($0))" }, unit: "bpm")
            Divider().overlay(Theme.creme.opacity(0.08))
            fitnessRow("VO₂ max", value: health?.vo2Max.map { String(format: "%.0f", $0) }, unit: "ml/kg/min")
            Divider().overlay(Theme.creme.opacity(0.08))
            fitnessRow("Variabilité cardiaque", value: health?.hrv.map { "\(Int($0))" }, unit: "ms")
        }
        .card()
    }

    private func fitnessRow(_ title: String, value: String?, unit: String) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? (loadingHealth ? "…" : "--")).font(.display(22, weight: .black).monospacedDigit()).foregroundStyle(Theme.creme)
                Text(unit).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.creme)
            }
        }
        .frame(height: 48)
    }

    private var last30Card: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tes 30 derniers jours").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.creme)
            HStack(spacing: 0) {
                bigStat("\(health?.last30DaysWorkouts ?? 0)", "séances")
                Divider().overlay(Theme.creme.opacity(0.1)).frame(height: 44)
                bigStat(Formatters.humanDuration((health?.last30DaysMinutes ?? 0) * 60), "d'activité")
                Divider().overlay(Theme.creme.opacity(0.1)).frame(height: 44)
                bigStat(String(format: "%.1f", health?.last30DaysKm ?? 0).replacingOccurrences(of: ".", with: ","), "km")
            }
            Text("Toutes apps confondues").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
        }
        .card()
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.display(22, weight: .black).monospacedDigit()).foregroundStyle(Theme.creme).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Contexte, mémoire, ressentis

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("À propos de toi").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.creme)
                Spacer()
                Button { notesFocused = true } label: { Image(systemName: "pencil").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.creme) }
            }
            TextField("Ta forme du jour, tes contraintes, ce que Jeffrey doit savoir…", text: $athleteNotes, axis: .vertical)
                .lineLimit(3...6).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.creme)
                .focused($notesFocused)
                .padding(12).frame(minHeight: 96, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceRaised))
            Text("Tu peux modifier ces infos à tout moment.").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
        }
        .card()
    }

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                JeffreyMark(size: 20)
                Text("Ce que Jeffrey retient de toi").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.creme)
            }
            if memory.notes.isEmpty {
                Text("Rien encore. Après chaque séance, Jeffrey note ce qui compte sur la durée : une gêne, un objectif, une préférence. Tu peux aussi lui écrire directement.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
            }
            ForEach(memory.notes) { note in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(Theme.citron).frame(width: 6, height: 6).padding(.top, 6)
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
                Button { memory.add(newNote); newNote = "" } label: {
                    JIcon("valider", size: 16).foregroundStyle(Theme.background)
                        .frame(width: 40, height: 40).background(Circle().fill(Theme.citron))
                }
                .disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .card()
    }

    private var feelingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tes derniers ressentis").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.creme)
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
        .card()
    }

    // MARK: Helpers

    private func titled<Content: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.creme)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }

    private func loadHealth() async {
        loadingHealth = true
        health = await SessionAnalyst.healthContext()
        loadingHealth = false
    }
}
