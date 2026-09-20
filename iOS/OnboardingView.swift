import SwiftUI
import UIKit
import AuthenticationServices

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
        case .restart: return "course"
        case .keepPace: return "progression"
        case .prepareGoal: return "objectif"
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

/// Premier lancement, pas à pas : une chose par écran, chaque étape vérifiée (✓) avant la première séance, les
/// autorisations demandées dans leur contexte, et un tour d'essai de deux minutes pour finir.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, you, watch, mic, outdoors, account, voice, recap
    }

    @EnvironmentObject private var coach: CoachSession
    @StateObject private var setup = SetupState()
    @ObservedObject private var account = AccountStore.shared
    @State private var showOwnKey = false
    @StateObject private var preview = VoicePreview()
    @StateObject private var appleVoice = AppleVoice()
    @AppStorage(Prefs.onboarded) private var onboarded: Bool = false
    @AppStorage(Prefs.setupVersion) private var setupVersion: Int = 0
    @AppStorage(Prefs.intent) private var intentRaw: String = ""
    @AppStorage(Prefs.level) private var level: String = AthleteLevel.amateur.rawValue
    @AppStorage(Prefs.userName) private var userName: String = ""
    @AppStorage(Prefs.goal) private var goal: String = ""
    @AppStorage(Prefs.age) private var age: Int = 40
    @AppStorage(Prefs.weightKg) private var weightKg: Double = 0
    @AppStorage(Prefs.heightCm) private var heightCm: Double = 0
    @AppStorage(Prefs.voiceEngine) private var voiceEngine: String = "openai"
    @AppStorage(Prefs.analysisProvider) private var analysisProvider: String = "apple"
    @AppStorage(Prefs.voice) private var voice: String = "marin"
    @AppStorage(Prefs.mode) private var modeRaw: String = CaptureMode.companion.rawValue
    @State private var step: Step = .welcome
    @State private var apiKey = KeychainStore.read(KeychainStore.apiKeyAccount) ?? ""
    @State private var voiceSampled = false
    @AppStorage(Prefs.aiProvider) private var aiProvider: String = "jeffrey"
    /// Apple AI demande Apple Intelligence sur l'iPhone (modèle local ou cloud privé).
    private var appleAIAvailable: Bool { AppleAnalyst.availableBackend(preferLocal: true) != nil }
    @FocusState private var focused: Bool

    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity))
    }
    private let ink = Color.white

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                progress
                // Une seule étape vivante à la fois (un TabView paginé garde toutes les pages actives).
                Group {
                    switch step {
                    case .welcome: welcome.transition(stepTransition)
                    case .you: you.transition(stepTransition)
                    case .watch: watchStep.transition(stepTransition)
                    case .mic: micStep.transition(stepTransition)
                    case .outdoors: outdoors.transition(stepTransition)
                    case .account: accountStep.transition(stepTransition)
                    case .voice: voiceStep.transition(stepTransition)
                    case .recap: recap.transition(stepTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.lime)
        .onAppear { syncWatch() }
        .onReceive(coach.connectivity.objectWillChange) { _ in DispatchQueue.main.async { syncWatch() } }
        .onChange(of: step) { old, _ in
            if old == .mic { setup.stopMicMeter() }
            focused = false
        }
    }

    private func syncWatch() {
        setup.updateWatch(paired: coach.connectivity.isPaired, installed: coach.connectivity.isWatchAppInstalled)
    }

    // MARK: Barre de progression

    private var progress: some View {
        HStack(spacing: 5) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule().fill(s.rawValue <= step.rawValue ? Theme.lime : ink.opacity(0.15)).frame(height: 4)
            }
        }
        .padding(.horizontal, 24).padding(.top, 14)
    }

    // MARK: 1. Bonjour

    private var welcome: some View {
        page(title: onboarded ? "Du nouveau." : "Moi, c'est Jeffrey.", subtitle: onboarded ? "Jeffrey a évolué : compte, montre, micro… On refait le tour ensemble, deux minutes, tout est déjà pré-rempli." : "Ton coach vocal. On prend deux minutes pour tout régler, puis on ne touche plus au téléphone.") {
            VStack(spacing: 10) {
                ForEach(Intent.allCases) { intent in
                    Button {
                        intentRaw = intent.rawValue
                        level = intent.level.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            JIcon(intent.icon, size: 20).frame(width: 22)
                            Text(intent.label).font(.system(size: 16, weight: .bold))
                            Spacer()
                            JIcon(intentRaw == intent.rawValue ? "valider" : "suivant", size: 16)
                                .foregroundStyle(intentRaw == intent.rawValue ? Theme.background : ink.opacity(0.4))
                        }
                        .foregroundStyle(intentRaw == intent.rawValue ? Theme.background : ink)
                        .padding(.horizontal, 16).frame(height: 58)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(intentRaw == intent.rawValue ? Theme.lime : Theme.surface))
                    }
                }
            }
            tip("Pour la meilleure expérience : une Apple Watch au poignet et des écouteurs avec micro (AirPods ou casque).")
        } footer: {
            primaryButton("On fait connaissance") { go(.you) }
                .disabled(intentRaw.isEmpty).opacity(intentRaw.isEmpty ? 0.4 : 1)
        }
    }

    // MARK: 2. Toi

    private var you: some View {
        page(title: "Dis-m'en un peu plus.", subtitle: "Ton prénom pour qu'il t'appelle, et Santé pour qu'il connaisse tes zones cardiaques.") {
            field("Ton prénom", text: $userName)
            if intentRaw == Intent.prepareGoal.rawValue {
                field("Ton objectif (ex. 10 km sous 50 min en novembre)", text: $goal)
            }
            checkRow(icon: "frequence-cardiaque", title: "Âge, poids et taille depuis Santé", status: setup.health,
                     detail: setup.health == .ok ? "\(age) ans\(weightKg > 0 ? ", \(Int(weightKg)) kg" : "")\(heightCm > 0 ? ", \(Int(heightCm)) cm" : "")"
                        : (setup.health == .missing ? "Rien trouvé dans Santé, tu compléteras dans Toi." : nil),
                     action: "Récupérer") { Task { await setup.requestHealth() } }
        } footer: {
            primaryButton("Continuer") { go(.watch) }
        }
    }

    // MARK: 3. Montre

    private var watchStep: some View {
        page(title: "Ta montre.", subtitle: "Jeffrey lit ton cœur sur l'Apple Watch. Sans elle, pas de séance.") {
            checkRow(icon: "montre", title: setup.watch == .ok ? "Jeffrey est sur ta montre" : (setup.watchPairedWithoutApp ? "Montre trouvée, Jeffrey n'y est pas encore" : "Aucune montre jumelée"),
                     status: setup.watch,
                     detail: setup.watch == .ok ? nil : (setup.watchPairedWithoutApp ? "Dans l'app Watch › Apps disponibles, installe Jeffrey. Cette page se mettra à jour toute seule." : "Jumelle une Apple Watch dans l'app Watch, puis reviens ici."),
                     action: setup.watch == .ok ? nil : "Ouvrir l'app Watch") {
                if let url = URL(string: "itms-watchs://"), UIApplication.shared.canOpenURL(url) { UIApplication.shared.open(url) }
            }
            if setup.watch != .ok {
                ProgressView().tint(Theme.lime).frame(maxWidth: .infinity)
                Text("J'attends la montre…").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
            }
        } footer: {
            primaryButton("Continuer") { go(.mic) }.disabled(setup.watch != .ok).opacity(setup.watch == .ok ? 1 : 0.4)
            skipButton("Passer, je la brancherai plus tard") { go(.mic) }
        }
    }

    // MARK: 4. Micro

    private var micStep: some View {
        page(title: "Ta voix.", subtitle: "Jeffrey t'écoute en continu pendant la séance. Autorise le micro, puis dis-lui bonjour.") {
            checkRow(icon: "micro", title: "Micro", status: setup.microphone,
                     detail: setup.microphone == .missing ? "Micro refusé : Réglages › Jeffrey › Micro." : nil,
                     action: setup.microphone == .ok ? nil : (setup.microphone == .missing ? "Ouvrir Réglages" : "Autoriser")) {
                if setup.microphone == .missing { openSettings() } else { Task { await setup.requestMicrophone(); if setup.microphone == .ok { setup.startMicMeter() } } }
            }
            if setup.microphone == .ok {
                VStack(spacing: 10) {
                    micMeter
                    Text(setup.micHeard ? "Je t'entends ✓" : "Dis quelque chose…")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(setup.micHeard ? Theme.lime : Theme.muted)
                }
                .padding(16).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
                .onAppear { setup.startMicMeter() }
            }
            tip("Avec des écouteurs à micro (AirPods, casque), Jeffrey t'entend même dans le vent ; l'iPhone peut rester dans la poche.")
        } footer: {
            primaryButton("Continuer") { go(.outdoors) }.disabled(setup.microphone != .ok).opacity(setup.microphone == .ok ? 1 : 0.4)
            skipButton("Passer") { go(.outdoors) }
        }
    }

    private var micMeter: some View {
        HStack(spacing: 4) {
            ForEach(0..<24, id: \.self) { i in
                let on = Double(i) / 24 < setup.micLevel
                Capsule().fill(on ? Theme.lime : ink.opacity(0.12)).frame(height: 8 + CGFloat(i % 5) * 4)
            }
        }
        .frame(height: 28)
        .animation(.linear(duration: 0.08), value: setup.micLevel)
    }

    // MARK: 5. Dehors

    private var outdoors: some View {
        page(title: "Dehors.", subtitle: "Le tracé de ta sortie, et ce que fait ton corps : marche, course, montée, descente.") {
            checkRow(icon: "parcours", title: "Position (tracé GPS)", status: setup.location,
                     detail: setup.location == .missing ? "Refusée : Réglages › Jeffrey › Position." : nil,
                     action: setup.location == .ok ? nil : (setup.location == .missing ? "Ouvrir Réglages" : "Autoriser")) {
                if setup.location == .missing { openSettings() } else { Task { await setup.requestLocation() } }
            }
            checkRow(icon: "course", title: "Mouvement (marche, course, relief)", status: setup.motion,
                     detail: setup.motion == .missing ? "Refusé : Réglages › Jeffrey › Mouvement et forme." : nil,
                     action: setup.motion == .ok ? nil : (setup.motion == .missing ? "Ouvrir Réglages" : "Autoriser")) {
                if setup.motion == .missing { openSettings() } else { Task { await setup.requestMotion() } }
            }
        } footer: {
            primaryButton("Continuer") { go(.account) }
                .disabled(setup.location != .ok || setup.motion != .ok).opacity(setup.location == .ok && setup.motion == .ok ? 1 : 0.4)
            skipButton("Passer") { go(.account) }
        }
    }

    // MARK: 6. Compte

    private var accountStep: some View {
        page(title: "Ton compte.", subtitle: "Connecte-toi avec Apple : un bouton, rien à saisir. Ton profil, ta mémoire et tes séances restent sur l'iPhone — Jeffrey est à toi, personne d'autre ne partage ce qu'il sait de toi. (Inutile si tu choisis Apple AI à l'étape suivante.)") {
            if let u = account.user, account.isSignedIn {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        JIcon("profil", size: 20).foregroundStyle(u.canUse ? Theme.lime : Theme.ember).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(u.name ?? u.email ?? "Compte Apple").font(.system(size: 15, weight: .bold)).foregroundStyle(ink)
                            Text(u.roleLabel).font(.system(size: 13, weight: .medium)).foregroundStyle(u.canUse ? Theme.lime : Theme.ember)
                        }
                        Spacer()
                        if u.canUse { JIcon("valider", size: 18).foregroundStyle(Theme.lime) } else { ProgressView().tint(Theme.ember) }
                    }
                    if u.role == "pending" {
                        Text("Demande envoyée. Hervé doit t'autoriser ; cette page se met à jour toute seule. En attendant, tu peux finir la configuration.")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    } else if u.role == "blocked" {
                        Text("Accès désactivé. Contacte Hervé.").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ember)
                    }
                    Button("Se déconnecter") { account.signOut(); setup.refreshAccess() }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
                .task {
                    // Rôle rafraîchi toutes les 5 s tant que la demande est en attente.
                    while !Task.isCancelled, account.user?.role == "pending" {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        await account.refresh(); setup.refreshAccess()
                    }
                }
            } else {
                SignInWithAppleButton(.continue, onRequest: { _ in }, onCompletion: { _ in })
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 54)
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                    .overlay(
                        Button { Task { await account.signInWithApple(); setup.refreshAccess() } } label: { Color.clear.contentShape(Capsule()) }
                            .disabled(account.isBusy)
                    )
                    .opacity(account.isBusy ? 0.6 : 1)
                if account.isBusy { ProgressView().tint(Theme.lime).frame(maxWidth: .infinity) }
                if let e = account.error { statusLine(ok: false, e) }
            }
            // Clé perso : réservé à l'administrateur (ou à un téléphone qui en a déjà une).
            if account.user?.isAdmin == true || !(KeychainStore.read(KeychainStore.apiKeyAccount) ?? "").isEmpty {
            Button { withAnimation(.snappy) { showOwnKey.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("J'ai ma propre clé OpenAI").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    JIcon("suivant", size: 12).foregroundStyle(Theme.muted).rotationEffect(.degrees(showOwnKey ? 90 : 0))
                }
                .frame(maxWidth: .infinity)
            }
            if showOwnKey { ownKeyFields }
            }
        } footer: {
            primaryButton("Continuer") { go(.voice) }.disabled(setup.access != .ok).opacity(setup.access == .ok ? 1 : 0.4)
            skipButton(account.user?.role == "pending" ? "Continuer en attendant" : "Plus tard") { go(.voice) }
        }
        .onAppear { setup.refreshAccess() }
    }

    private var ownKeyFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("sk-…", text: $apiKey, axis: .vertical)
                .focused($focused)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(3...6)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
            HStack(spacing: 12) {
                Button {
                    if let pasted = UIPasteboard.general.string { apiKey = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
                } label: {
                    HStack(spacing: 8) { JIcon("information", size: 16); Text("Coller") }.font(.system(size: 14, weight: .bold)).foregroundStyle(ink)
                        .padding(.horizontal, 14).frame(height: 40).background(Capsule().fill(Theme.surface))
                }
                Button {
                    focused = false
                    Task { await setup.saveAndCheckApiKey(apiKey) }
                } label: {
                    HStack(spacing: 8) {
                        if setup.apiKey == .checking { ProgressView().tint(Theme.background) } else { JIcon("valider", size: 16) }
                        Text(setup.apiKey == .checking ? "Vérification…" : "Vérifier")
                    }
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.background)
                    .padding(.horizontal, 14).frame(height: 40).background(Capsule().fill(Theme.lime))
                }
                .disabled(!apiKey.hasPrefix("sk-") || setup.apiKey == .checking)
                .opacity(apiKey.hasPrefix("sk-") ? 1 : 0.4)
            }
            if setup.apiKey == .ok {
                statusLine(ok: true, "Clé valide, Jeffrey peut parler.")
            } else if let e = setup.apiKeyError {
                statusLine(ok: false, e)
            }
        }
    }

    // MARK: 7. Intelligence

    private var voiceStep: some View {
        page(title: "Son intelligence.", subtitle: "Qui fait réfléchir et parler Jeffrey ? Tu pourras en changer dans l'onglet Jeffrey.") {
            voiceChoice(id: "openai", title: "Jeffrey AI", detail: "Recommandé. Voix naturelle, conversation fluide en séance, bilan détaillé. Passe par ton compte Jeffrey.", available: setup.access == .ok)
            voiceChoice(id: "apple", title: "Apple AI", detail: "Tout sur l'iPhone, sans compte ni réseau : moins performant, voix plus mécanique, mais rien ne sort du téléphone.", available: appleAIAvailable)
            Button {
                if voiceEngine == "apple" {
                    appleVoice.refresh()
                    appleVoice.speak("Salut\(userName.isEmpty ? "" : " \(userName)"), moi c'est Jeffrey. On y va à ton rythme.")
                    voiceSampled = true
                } else {
                    preview.play(voice: voice, name: userName)
                    voiceSampled = true
                }
            } label: {
                HStack(spacing: 8) {
                    if preview.isLoading { ProgressView().tint(ink) } else { JIcon("lecture", size: 16) }
                    Text(preview.isLoading ? "Jeffrey arrive…" : "Écouter un extrait")
                }
                .font(.system(size: 15, weight: .bold)).foregroundStyle(ink)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
            }
            .disabled(voiceEngine == "openai" && setup.access != .ok)
            .opacity(voiceEngine == "openai" && setup.access != .ok ? 0.4 : 1)
            if let e = preview.error { statusLine(ok: false, e) }
            else if voiceSampled, !preview.isLoading { statusLine(ok: true, "C'est lui.") }
        } footer: {
            primaryButton("Continuer") { go(.recap) }
        }
    }

    private func voiceChoice(id: String, title: String, detail: String, available: Bool) -> some View {
        let selected = voiceEngine == id
        return Button {
            voiceEngine = id
            // Apple AI : cerveau, écoute, voix et bilan sur l'iPhone. Jeffrey AI : OpenAI en séance, bilan Apple d'abord.
            aiProvider = id == "apple" ? "apple" : "jeffrey"
            analysisProvider = "apple"
            voiceSampled = false
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(selected ? Theme.background : ink)
                    Text(available ? detail : "Connecte-toi (étape précédente) pour l'utiliser.").font(.system(size: 13, weight: .medium)).foregroundStyle(selected ? Theme.background.opacity(0.7) : Theme.muted)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                JIcon(selected ? "valider" : "suivant", size: 16).foregroundStyle(selected ? Theme.background : ink.opacity(0.4))
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? Theme.lime : Theme.surface))
        }
        .disabled(!available)
        .opacity(available ? 1 : 0.5)
    }

    // MARK: 8. Récap + tour d'essai

    private var recap: some View {
        page(title: setup.allReady ? "Tout est prêt." : "Presque prêt.", subtitle: setup.allReady ? "Un tour d'essai de deux minutes, sans sortir, pour l'entendre une première fois ?" : "Ce qui manque est en orange, tu peux le régler maintenant ou plus tard dans l'onglet Jeffrey.") {
            VStack(spacing: 8) {
                recapRow("Profil", setup.health, .you)
                recapRow("Apple Watch", setup.watch, .watch)
                recapRow("Micro", setup.microphone, .mic)
                recapRow("Position", setup.location, .outdoors)
                recapRow("Mouvement", setup.motion, .outdoors)
                if aiProvider != "apple" { recapRow("Compte Jeffrey", setup.access, .account) }
            }
        } footer: {
            let canTrial = setup.watch == .ok && setup.microphone == .ok && (setup.access == .ok || aiProvider == "apple")
            primaryButton("Faire un tour d'essai (2 min)") {
                onboarded = true
                setupVersion = Prefs.currentSetupVersion
                UserDefaults.standard.set(WorkoutKind.walking.rawValue, forKey: Prefs.kind)
                coach.start(kind: .walking, mode: .owned, goal: .trial)
            }
            .disabled(!canTrial).opacity(canTrial ? 1 : 0.4)
            skipButton(canTrial ? "Commencer sans tour d'essai" : "Commencer") { onboarded = true; setupVersion = Prefs.currentSetupVersion }
        }
        .onAppear { setup.refresh(); syncWatch() }
    }

    private func recapRow(_ title: String, _ status: SetupState.Status, _ target: Step) -> some View {
        HStack(spacing: 12) {
            Circle().fill(status == .ok ? Theme.lime : Theme.ember).frame(width: 10, height: 10)
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(ink)
            Spacer()
            if status == .ok {
                Text("Prêt").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            } else {
                Button("Régler") { go(target) }.font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ember)
            }
        }
        .padding(.horizontal, 16).frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
    }

    // MARK: Briques

    private func go(_ s: Step) { withAnimation { step = s } }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private func page<Content: View, Footer: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    JeffreyMark(size: 40).padding(.top, 22)
                    Text(title).font(.display(32, weight: .black)).foregroundStyle(ink)
                    Text(subtitle).font(.system(size: 16, weight: .medium)).foregroundStyle(ink.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                    content()
                }
                .padding(.horizontal, 24).padding(.bottom, 12)
            }
            VStack(spacing: 8) { footer() }.padding(.horizontal, 24).padding(.bottom, 16)
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            JIcon("ecouteurs", size: 18).foregroundStyle(Theme.lime)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.lime.opacity(0.08)))
    }

    private func statusLine(ok: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            JIcon(ok ? "valider" : "information", size: 14).foregroundStyle(ok ? Theme.lime : Theme.ember)
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(ok ? Theme.lime : Theme.ember)
        }
    }

    /// Ligne de vérification : icône, titre, état (✓ / … / !), détail, bouton d'action.
    private func checkRow(icon: String, title: String, status: SetupState.Status, detail: String?, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                JIcon(icon, size: 20).foregroundStyle(status == .ok ? Theme.lime : ink).frame(width: 24)
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                Spacer()
                switch status {
                case .ok: JIcon("valider", size: 18).foregroundStyle(Theme.lime)
                case .checking: ProgressView().tint(Theme.lime)
                case .missing: JIcon("information", size: 18).foregroundStyle(Theme.ember)
                case .unknown: EmptyView()
                }
            }
            if let detail { Text(detail).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            if let action, status != .ok {
                Button(action: perform) {
                    Text(action).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.background)
                        .padding(.horizontal, 16).frame(height: 40).background(Capsule().fill(Theme.lime))
                }
                .disabled(status == .checking)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .focused($focused)
            .font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 16).frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.display(17, weight: .black)).foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity).frame(height: 58)
                .background(Capsule().fill(Theme.lime))
        }
    }

    private func skipButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).frame(height: 36)
        }
    }
}
