import SwiftUI

enum Intent: String, CaseIterable, Identifiable {
    case restart, keepPace, prepareGoal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .restart: return "Me remettre au sport"
        case .keepPace: return "Garder le rythme"
        case .prepareGoal: return "Préparer un objectif"
        }
    }
    var icon: String {
        switch self {
        case .restart: return "figure.run"
        case .keepPace: return "chart.bar.fill"
        case .prepareGoal: return "scope"
        }
    }
    var coachLabel: String {
        switch self {
        case .restart: return "se remettre au sport en douceur, sans se dégoûter"
        case .keepPace: return "garder un rythme régulier et du plaisir"
        case .prepareGoal: return "préparer un objectif précis"
        }
    }
    var level: AthleteLevel {
        switch self {
        case .restart: return .beginner
        case .keepPace: return .amateur
        case .prepareGoal: return .confirmed
        }
    }
}

/// Premier lancement, sur fond clair : Jeffrey se présente et fait connaissance.
struct OnboardingView: View {
    @AppStorage(Prefs.onboarded) private var onboarded: Bool = false
    @AppStorage(Prefs.intent) private var intentRaw: String = ""
    @AppStorage(Prefs.level) private var level: String = AthleteLevel.amateur.rawValue
    @AppStorage(Prefs.userName) private var userName: String = ""
    @AppStorage(Prefs.goal) private var goal: String = ""
    @AppStorage(Prefs.age) private var age: Int = 40
    @AppStorage(Prefs.weightKg) private var weightKg: Double = 0
    @AppStorage(Prefs.heightCm) private var heightCm: Double = 0
    @State private var step = 0
    @State private var apiKey = KeychainStore.read(KeychainStore.apiKeyAccount) ?? ""
    @State private var healthNotice: String?

    private let cream = Color(red: 0.96, green: 0.95, blue: 0.91)
    private let ink = Color(red: 0.06, green: 0.06, blue: 0.07)

    var body: some View {
        ZStack {
            cream.ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $step) {
                    intro.tag(0)
                    profile.tag(1)
                    keyStep.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule().fill(i == step ? Theme.lime : ink.opacity(0.15)).frame(width: i == step ? 22 : 8, height: 8)
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .preferredColorScheme(.light)
        .tint(ink)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            JeffreyMark(size: 56).padding(.top, 30)
            VStack(alignment: .leading, spacing: 4) {
                Text("Moi, c'est").font(.display(34, weight: .black)).foregroundStyle(ink)
                Text("Jeffrey.").font(.display(34, weight: .black)).foregroundStyle(ink.opacity(0.45))
            }
            Text("On commence par toi.").font(.system(size: 17, weight: .medium)).foregroundStyle(ink.opacity(0.7))
            VStack(spacing: 10) {
                ForEach(Intent.allCases) { intent in
                    Button {
                        intentRaw = intent.rawValue
                        level = intent.level.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: intent.icon).font(.system(size: 15, weight: .bold)).frame(width: 22)
                            Text(intent.label).font(.system(size: 16, weight: .bold))
                            Spacer()
                            Image(systemName: intentRaw == intent.rawValue ? "checkmark.circle.fill" : "chevron.right")
                                .foregroundStyle(intentRaw == intent.rawValue ? Theme.lime : ink.opacity(0.4))
                        }
                        .foregroundStyle(intentRaw == intent.rawValue ? cream : ink)
                        .padding(.horizontal, 16).frame(height: 58)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(intentRaw == intent.rawValue ? ink : ink.opacity(0.06)))
                    }
                }
            }
            .padding(.top, 8)
            Spacer()
            primaryButton("On fait connaissance") { withAnimation { step = 1 } }
                .disabled(intentRaw.isEmpty)
                .opacity(intentRaw.isEmpty ? 0.4 : 1)
        }
        .padding(24)
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 18) {
            JeffreyMark(size: 40).padding(.top, 30)
            Text("Dis-m'en un peu plus.").font(.display(30, weight: .black)).foregroundStyle(ink)
            field("Ton prénom", text: $userName)
            if intentRaw == Intent.prepareGoal.rawValue {
                field("Ton objectif (ex. 10 km sous 50 min en novembre)", text: $goal)
            }
            Button {
                Task {
                    let r = await HealthProfile.fetch()
                    if let a = r.age { age = a }
                    if let h = r.heightCm { heightCm = h }
                    if let w = r.weightKg { weightKg = w }
                    healthNotice = r.age == nil && r.weightKg == nil ? "Rien trouvé dans Santé, tu pourras compléter dans les réglages."
                        : "Récupéré depuis Santé : \(age) ans\(weightKg > 0 ? ", \(Int(weightKg)) kg" : "")\(heightCm > 0 ? ", \(Int(heightCm)) cm" : "")."
                }
            } label: {
                Label("Récupérer âge, poids et taille depuis Santé", systemImage: "heart.text.square")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(ink)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ink.opacity(0.06)))
            }
            if let healthNotice { Text(healthNotice).font(.footnote).foregroundStyle(ink.opacity(0.6)) }
            Spacer()
            primaryButton("Continuer") { withAnimation { step = 2 } }
        }
        .padding(24)
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            JeffreyMark(size: 40).padding(.top, 30)
            Text("Dernière chose.").font(.display(30, weight: .black)).foregroundStyle(ink)
            Text("Jeffrey parle grâce à OpenAI. Colle ta clé API : elle reste dans le trousseau de ton iPhone.")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(ink.opacity(0.7))
            TextField("sk-…", text: $apiKey, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(3...6)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ink.opacity(0.06)))
            Button {
                if let pasted = UIPasteboard.general.string { apiKey = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
            } label: {
                Label("Coller depuis le presse-papiers", systemImage: "doc.on.clipboard").font(.system(size: 14, weight: .bold)).foregroundStyle(ink)
            }
            Spacer()
            primaryButton(apiKey.hasPrefix("sk-") ? "C'est parti" : "Plus tard") {
                if apiKey.hasPrefix("sk-") { KeychainStore.write(apiKey, account: KeychainStore.apiKeyAccount) }
                onboarded = true
            }
        }
        .padding(24)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 16).frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ink.opacity(0.06)))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.display(17, weight: .black)).foregroundStyle(ink)
                .frame(maxWidth: .infinity).frame(height: 58)
                .background(Capsule().fill(Theme.lime))
        }
    }
}
