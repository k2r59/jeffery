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
    @State private var step: Step = .welcome
    @State private var apiKey = KeychainStore.read(KeychainStore.apiKeyAccount) ?? ""
    @State private var voiceSampled = false
    @AppStorage(Prefs.aiProvider) private var aiProvider: String = "jeffrey"
    /// Apple AI demande Apple Intelligence sur l'iPhone (modèle local ou cloud privé).
    private var appleAIAvailable: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WATCHCOACH_FAKE_APPLE_AI"] == "1" { return true }
        #endif
        return AppleAnalyst.availableBackend(preferLocal: true) != nil
    }
    @FocusState private var focused: Bool

    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity))
    }

    // Palette de la refonte (kit onboarding du 19/09/2026, styles/tokens.json)
    private let ink = Color(red: 0xF7 / 255, green: 0xF9 / 255, blue: 0xF4 / 255)
    private let bg = Color(red: 0x0C / 255, green: 0x12 / 255, blue: 0x0F / 255)
    private let surface = Color(red: 0x16 / 255, green: 0x1D / 255, blue: 0x17 / 255)
    private let selectedSurface = Color(red: 0x26 / 255, green: 0x33 / 255, blue: 0x1A / 255)
    private let accent = Color(red: 0xD4 / 255, green: 0xFF / 255, blue: 0x4F / 255)
    private let secondary = Color(red: 0xAF / 255, green: 0xBA / 255, blue: 0xA7 / 255)
    private let border = Color(red: 0x40 / 255, green: 0x50 / 255, blue: 0x3C / 255)
    private let warning = Color(red: 0xFF / 255, green: 0x9A / 255, blue: 0x4B / 255)
    private let disabledSurface = Color(red: 0x38 / 255, green: 0x40 / 255, blue: 0x3A / 255)
    private let disabledText = Color(red: 0xC0 / 255, green: 0xC6 / 255, blue: 0xBD / 255)
    private let cardRadius: CGFloat = 20
    private let fieldRadius: CGFloat = 14

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            // Lumière verte discrète en haut (illustrations/screen-background.svg).
            RadialGradient(colors: [Color(red: 0x3A / 255, green: 0x50 / 255, blue: 0x1B / 255).opacity(0.55), .clear],
                           center: .init(x: 0.3, y: 0.05), startRadius: 0, endRadius: 520)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                header
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
        .tint(accent)
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

    // MARK: En-tête et progression

    /// Retour, symbole + « Jeffrey », compteur n/8.
    private var header: some View {
        ZStack {
            // Logotype officiel « jeffrey » (J citron + effrey crème).
            Image("jeffrey-logo-creme").resizable().scaledToFit().frame(height: 32)
            HStack {
                Button {
                    if let previous = Step(rawValue: step.rawValue - 1) { go(previous) }
                } label: {
                    JIcon("retour", size: 18).foregroundStyle(ink).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)
                Spacer()
                Text("\(step.rawValue + 1)/\(Step.allCases.count)").font(.system(size: 15, weight: .medium)).foregroundStyle(secondary)
            }
        }
        .padding(.horizontal, 16).padding(.top, 4)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule().fill(s.rawValue <= step.rawValue ? accent : ink.opacity(0.14)).frame(height: 4)
            }
        }
        .padding(.horizontal, 24).padding(.top, 8)
    }

    // MARK: 1. Bonjour

    private var welcome: some View {
        page(title: onboarded ? "Du nouveau." : "Ton rythme. Ton coach.",
             subtitle: onboarded ? "Jeffrey a évolué : compte, montre, micro… On refait le tour ensemble, deux minutes, tout est déjà pré-rempli." : "Prenons deux minutes pour faire connaissance.",
             centered: true) {
            Text("Qu'est-ce qui te motive ?").font(.system(size: 16, weight: .semibold)).foregroundStyle(ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 10) {
                ForEach(Intent.allCases) { intent in
                    let selected = intentRaw == intent.rawValue
                    Button {
                        intentRaw = intent.rawValue
                        level = intent.level.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            radio(selected)
                            JIcon(intent.icon, size: 20).foregroundStyle(selected ? accent : ink).frame(width: 22)
                            Text(intent.label).font(.system(size: 16, weight: .semibold)).foregroundStyle(ink)
                            Spacer()
                        }
                        .padding(.horizontal, 16).frame(height: 58)
                        .background(cardShape(selected: selected))
                    }
                    .buttonStyle(.plain)
                }
            }
            Rectangle().fill(border).frame(height: 1).padding(.top, 4)
            HStack(alignment: .top, spacing: 12) {
                JIcon("ecouteurs", size: 20).foregroundStyle(accent)
                Text("Apple Watch et écouteurs avec micro conseillés pour la meilleure expérience.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            primaryButton("Faire connaissance", enabled: !intentRaw.isEmpty) { go(.you) }
        }
    }

    // MARK: 2. Toi

    private var you: some View {
        page(title: "On commence par toi.", subtitle: "Ton prénom et tes données Santé pour adapter tes zones cardiaques.", centered: true) {
            fieldLabel("Ton prénom")
            field("Prénom", text: $userName)
            if intentRaw == Intent.prepareGoal.rawValue {
                fieldLabel("Ton objectif")
                field("ex. 10 km sous 50 min en novembre", text: $goal)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white).frame(width: 56, height: 56)
                        Image(systemName: "heart.fill").font(.system(size: 26)).foregroundStyle(Color(red: 1, green: 0.23, blue: 0.4))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Apple Santé").font(.system(size: 16, weight: .bold)).foregroundStyle(ink)
                        Text(setup.health == .ok ? "\(age) ans\(weightKg > 0 ? ", \(Int(weightKg)) kg" : "")\(heightCm > 0 ? ", \(Int(heightCm)) cm" : "")"
                             : (setup.health == .missing ? "Rien trouvé dans Santé, tu compléteras dans Toi." : "Pour un coaching vraiment personnalisé."))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(setup.health == .missing ? warning : secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if setup.health == .ok { checkBadge() } else if setup.health == .checking { ProgressView().tint(accent) }
                }
                HStack(spacing: 10) {
                    chip("profil", "Âge"); chip("energie", "Poids"); chip("progression", "Taille")
                }
            }
            .padding(16)
            .background(cardShape())
            Rectangle().fill(border).frame(height: 1)
            Text("Récupère tes informations depuis Santé.").font(.system(size: 14, weight: .medium)).foregroundStyle(secondary).frame(maxWidth: .infinity)
            outlineButton(setup.health == .ok ? "Mettre à jour depuis Santé" : "Récupérer mes données", busy: setup.health == .checking) { Task { await setup.requestHealth() } }
        } footer: {
            primaryButton("Continuer") { go(.watch) }
        }
    }

    // MARK: 3. Montre

    private var watchStep: some View {
        page(title: "Ton cœur donne le tempo.", subtitle: "Ton Apple Watch transmet ton rythme cardiaque à Jeffrey.", centered: true) {
            checkRow(icon: "montre", title: setup.watch == .ok ? "Jeffrey est sur ta montre" : (setup.watchPairedWithoutApp ? "Montre trouvée, Jeffrey n'y est pas encore" : "Aucune montre jumelée"),
                     status: setup.watch,
                     detail: setup.watch == .ok ? "Connectée et prête à t'accompagner." : (setup.watchPairedWithoutApp ? "Dans l'app Watch › Apps disponibles, installe Jeffrey. Cette page se mettra à jour toute seule." : "Jumelle une Apple Watch dans l'app Watch, puis reviens ici."),
                     badge: setup.watch == .ok ? "Prête" : nil,
                     action: setup.watch == .ok ? nil : "Ouvrir l'app Watch") {
                if let url = URL(string: "itms-watchs://"), UIApplication.shared.canOpenURL(url) { UIApplication.shared.open(url) }
            }
            if setup.watch != .ok {
                HStack(spacing: 8) { ProgressView().tint(accent); Text("J'attends la montre…").font(.system(size: 13, weight: .medium)).foregroundStyle(secondary) }
                    .frame(maxWidth: .infinity)
            }
            Rectangle().fill(border).frame(height: 1)
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "info.circle").font(.system(size: 20)).foregroundStyle(secondary)
                Text("Nécessaire pour démarrer une séance.").font(.system(size: 16, weight: .medium)).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        } footer: {
            primaryButton("Continuer", enabled: setup.watch == .ok) { go(.mic) }
            skipButton("Passer, je la brancherai plus tard") { go(.mic) }
        }
    }

    // MARK: 4. Micro

    private var micStep: some View {
        page(title: "Parle.\nJeffrey t'écoute.", subtitle: "Autorise le micro et dis bonjour à ton coach.") {
            // Vumètre : vivant dès que le micro est autorisé, statique sinon.
            VStack(spacing: 14) {
                HStack(spacing: 18) {
                    micMeter(side: .left)
                    ZStack {
                        Circle().stroke(accent.opacity(setup.micHeard ? 0.9 : 0.35), lineWidth: 2).frame(width: 84, height: 84)
                        JIcon("micro", size: 30).foregroundStyle(accent)
                    }
                    micMeter(side: .right)
                }
                Text(setup.microphone == .ok ? (setup.micHeard ? "Je t'entends ✓" : "Dis quelque chose…") : "Autorise le micro pour l'essai")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(setup.micHeard ? accent : secondary)
            }
            .padding(.vertical, 22).frame(maxWidth: .infinity)
            .background(cardShape())
            .onAppear { if setup.microphone == .ok { setup.startMicMeter() } }
            checkRow(icon: "micro", title: "Microphone", status: setup.microphone,
                     detail: setup.microphone == .ok ? "Autorisé" : (setup.microphone == .missing ? "Micro refusé : Réglages › Jeffrey › Micro." : "Pour parler à Jeffrey pendant la séance."),
                     action: setup.microphone == .ok ? nil : (setup.microphone == .missing ? "Ouvrir Réglages" : "Autoriser")) {
                if setup.microphone == .missing { openSettings() } else { Task { await setup.requestMicrophone(); if setup.microphone == .ok { setup.startMicMeter() } } }
            }
            tip("Avec des écouteurs à micro, ton iPhone reste dans la poche.")
        } footer: {
            primaryButton("Continuer", enabled: setup.microphone == .ok) { go(.outdoors) }
        }
    }

    private enum MeterSide { case left, right }

    /// Onde vocale de part et d'autre du micro : les barres s'allument depuis le centre avec le niveau.
    private func micMeter(side: MeterSide) -> some View {
        let heights: [CGFloat] = [10, 18, 30, 44, 30, 18, 10]
        return HStack(spacing: 6) {
            ForEach(0..<heights.count, id: \.self) { i in
                let distance = side == .left ? Double(heights.count - 1 - i) : Double(i)
                let on = setup.microphone == .ok && setup.micLevel >= distance / Double(heights.count)
                Capsule().fill(accent.opacity(on ? 1 : 0.28)).frame(width: 5, height: heights[i])
            }
        }
        .frame(height: 44)
        .animation(.linear(duration: 0.08), value: setup.micLevel)
    }

    // MARK: 5. Dehors

    private var outdoors: some View {
        page(title: "Chaque sortie compte.", subtitle: "Retrouve ton parcours et suis tes mouvements.", illustration: "onb-route-map") {
            checkRow(icon: "parcours", title: "Position GPS", status: setup.location,
                     detail: setup.location == .missing ? "Refusée : Réglages › Jeffrey › Position." : "Le tracé de ta sortie",
                     statusLabel: "Autorisé",
                     action: setup.location == .ok ? nil : (setup.location == .missing ? "Ouvrir Réglages" : "Autoriser")) {
                if setup.location == .missing { openSettings() } else { Task { await setup.requestLocation() } }
            }
            checkRow(icon: "course", title: "Mouvement", status: setup.motion,
                     detail: setup.motion == .missing ? "Refusé : Réglages › Jeffrey › Mouvement et forme." : "Marche, course et relief",
                     statusLabel: "Autorisé",
                     action: setup.motion == .ok ? nil : (setup.motion == .missing ? "Ouvrir Réglages" : "Autoriser")) {
                if setup.motion == .missing { openSettings() } else { Task { await setup.requestMotion() } }
            }
        } footer: {
            primaryButton("Continuer", enabled: setup.location == .ok && setup.motion == .ok) { go(.account) }
        }
    }

    // MARK: 6. Compte

    private var accountStep: some View {
        page(title: "Ton coach, à toi.", subtitle: "Connecte-toi avec Apple pour continuer.") {
            if let u = account.user, account.isSignedIn {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        JIcon("profil", size: 20).foregroundStyle(u.canUse ? accent : warning).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(u.name ?? u.email ?? "Compte Apple").font(.system(size: 15, weight: .bold)).foregroundStyle(ink)
                            Text(u.roleLabel).font(.system(size: 13, weight: .medium)).foregroundStyle(u.canUse ? accent : warning)
                        }
                        Spacer()
                        if u.canUse { checkBadge() } else { ProgressView().tint(warning) }
                    }
                    if u.role == "pending" {
                        Text("Demande envoyée. Hervé doit t'autoriser ; cette page se met à jour toute seule. En attendant, tu peux finir la configuration.")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                    } else if u.role == "blocked" {
                        Text("Accès désactivé. Contacte Hervé.").font(.system(size: 13, weight: .medium)).foregroundStyle(warning)
                    }
                    Button("Se déconnecter") { account.signOut(); setup.refreshAccess() }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(secondary)
                }
                .padding(16)
                .background(cardShape())
                .task {
                    // Rôle rafraîchi toutes les 5 s tant que la demande est en attente.
                    while !Task.isCancelled, account.user?.role == "pending" {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        await account.refresh(); setup.refreshAccess()
                    }
                }
            } else {
                infoCard(system: "iphone", title: "Sur ton iPhone", text: "Ton profil, ta mémoire et tes séances restent sur ton appareil.")
                infoCard(system: "faceid", title: "Un bouton, rien à saisir.", text: "Face ID, et c'est fait. Le compte sert à t'identifier, pas à collecter.")
                SignInWithAppleButton(.continue, onRequest: { _ in }, onCompletion: { _ in })
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 56)
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                    .overlay(
                        Button { Task { await account.signInWithApple(); setup.refreshAccess() } } label: { Color.clear.contentShape(Capsule()) }
                            .disabled(account.isBusy)
                    )
                    .opacity(account.isBusy ? 0.6 : 1)
                if account.isBusy { ProgressView().tint(accent).frame(maxWidth: .infinity) }
                if let e = account.error { statusLine(ok: false, e) }
            }
            // Clé perso : réservé à l'administrateur (ou à un téléphone qui en a déjà une).
            if account.user?.isAdmin == true || !(KeychainStore.read(KeychainStore.apiKeyAccount) ?? "").isEmpty {
            Button { withAnimation(.snappy) { showOwnKey.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("J'ai ma propre clé OpenAI").font(.system(size: 13, weight: .semibold)).foregroundStyle(secondary)
                    JIcon("suivant", size: 12).foregroundStyle(secondary).rotationEffect(.degrees(showOwnKey ? 90 : 0))
                }
                .frame(maxWidth: .infinity)
            }
            if showOwnKey { ownKeyFields }
            }
        } footer: {
            // Compte Apple obligatoire : on continue une fois connecté.
            primaryButton("Continuer", enabled: account.isSignedIn) { go(.voice) }
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
                .background(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous).fill(surface).overlay(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous).strokeBorder(border)))
            HStack(spacing: 12) {
                Button {
                    if let pasted = UIPasteboard.general.string { apiKey = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
                } label: {
                    HStack(spacing: 8) { JIcon("information", size: 16); Text("Coller") }.font(.system(size: 14, weight: .bold)).foregroundStyle(ink)
                        .padding(.horizontal, 14).frame(height: 44).background(Capsule().fill(surface).overlay(Capsule().strokeBorder(border)))
                }
                Button {
                    focused = false
                    Task { await setup.saveAndCheckApiKey(apiKey) }
                } label: {
                    HStack(spacing: 8) {
                        if setup.apiKey == .checking { ProgressView().tint(bg) } else { JIcon("valider", size: 16) }
                        Text(setup.apiKey == .checking ? "Vérification…" : "Vérifier")
                    }
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(bg)
                    .padding(.horizontal, 14).frame(height: 44).background(Capsule().fill(accent))
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
        page(title: "Choisis ton intelligence.", subtitle: "Modifiable via « Refaire la configuration » dans l'onglet Jeffrey.") {
            voiceChoice(id: "openai", title: "Jeffrey AI", detail: "Recommandé. Voix naturelle, conversation fluide, bilan détaillé.", available: setup.access == .ok)
            voiceChoice(id: "apple", title: "Apple AI", detail: "Sur ton iPhone\nSans réseau\nVoix plus mécanique", available: appleAIAvailable)
            if voiceEngine == "apple" {
                infoLine("Moins performant, mais les échanges restent sur l'iPhone.")
            } else {
                infoLine("Le plus naturel. Les échanges passent par ton compte Jeffrey.")
            }
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
                let active = !(voiceEngine == "openai" && setup.access != .ok)
                HStack(spacing: 10) {
                    if preview.isLoading { ProgressView().tint(ink) } else { JIcon("lecture", size: 18).foregroundStyle(active ? accent : disabledText) }
                    Text(preview.isLoading ? "Jeffrey arrive…" : "Écouter un extrait")
                }
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(active ? ink : disabledText)
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(Capsule().fill(surface).overlay(Capsule().strokeBorder(active ? accent : border, lineWidth: 1.5)))
            }
            .buttonStyle(.plain)
            .disabled(voiceEngine == "openai" && setup.access != .ok)
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
            HStack(alignment: .top, spacing: 14) {
                // Pastille : le symbole Jeffrey (ou un cadenas tant que la connexion manque), ou la pomme.
                ZStack {
                    Circle().fill(Color.white.opacity(0.08)).frame(width: 48, height: 48)
                    if id == "apple" {
                        Image(systemName: "apple.logo").font(.system(size: 22, weight: .medium)).foregroundStyle(ink)
                    } else if available {
                        JeffreyMark(size: 24)
                    } else {
                        Image(systemName: "lock").font(.system(size: 20, weight: .medium)).foregroundStyle(ink)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(ink)
                    Text(available ? detail : "Connexion requise").font(.system(size: 14, weight: .medium)).foregroundStyle(secondary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if available { radio(selected).padding(.top, 8) }
            }
            .padding(16)
            .background(cardShape(selected: selected))
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }

    // MARK: 8. Récap + tour d'essai

    private var recap: some View {
        let rows: [(String, String, SetupState.Status, Step)] = [
            ("profil", "Profil", setup.health, .you), ("montre", "Apple Watch", setup.watch, .watch), ("micro", "Micro", setup.microphone, .mic),
            ("parcours", "Position", setup.location, .outdoors), ("course", "Mouvement", setup.motion, .outdoors),
        ] + (aiProvider != "apple" ? [("profil", "Compte Jeffrey", setup.access, .account)] : [])
        let missing = rows.filter { $0.2 != .ok }.count
        return page(title: setup.allReady ? "Tout est prêt." : "Presque prêt à partir.",
                    subtitle: setup.allReady ? "Un tour d'essai de deux minutes, sans sortir, pour l'entendre une première fois ?" : "\(missing == 1 ? "Un réglage reste" : "\(missing) réglages restent") à compléter.") {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    recapRow(icon: row.0, row.1, row.2, row.3)
                    if i < rows.count - 1 { Rectangle().fill(border).frame(height: 1).padding(.leading, 16) }
                }
            }
            .background(cardShape())
            infoLine("Tu retrouveras ces réglages dans l'onglet Jeffrey (« Refaire la configuration »).")
        } footer: {
            let canTrial = setup.watch == .ok && setup.microphone == .ok && (setup.access == .ok || aiProvider == "apple")
            primaryButton("Faire un tour d'essai · 2 min", enabled: canTrial) {
                onboarded = true
                setupVersion = Prefs.currentSetupVersion
                UserDefaults.standard.set(WorkoutKind.walking.rawValue, forKey: Prefs.kind)
                coach.start(kind: .walking, mode: .owned, goal: .trial)
            }
            if !canTrial {
                Text("Complète les réglages requis pour l'essai.").font(.system(size: 13, weight: .medium)).foregroundStyle(secondary).frame(maxWidth: .infinity)
            }
            Button { onboarded = true; setupVersion = Prefs.currentSetupVersion } label: {
                Text(canTrial ? "Commencer sans tour d'essai" : "Commencer").font(.system(size: 16, weight: .semibold)).foregroundStyle(accent)
                    .frame(maxWidth: .infinity).frame(height: 44)
            }
        }
        .onAppear { setup.refresh(); syncWatch() }
    }

    private func recapRow(icon: String, _ title: String, _ status: SetupState.Status, _ target: Step) -> some View {
        let feminine = ["Apple Watch", "Position"].contains(title)
        return Button { go(target) } label: {
            HStack(spacing: 12) {
                JIcon(icon, size: 18).foregroundStyle(ink).frame(width: 22)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
                Spacer()
                if status == .ok {
                    checkBadge(size: 20)
                    Text(feminine ? "Prête" : "Prêt").font(.system(size: 14, weight: .medium)).foregroundStyle(secondary)
                } else {
                    ZStack {
                        Circle().fill(warning).frame(width: 20, height: 20)
                        Text("!").font(.system(size: 13, weight: .heavy)).foregroundStyle(bg)
                    }
                    Text("À compléter").font(.system(size: 14, weight: .medium)).foregroundStyle(warning)
                    Text("Régler").font(.system(size: 14, weight: .bold)).foregroundStyle(accent).padding(.leading, 4)
                }
                JIcon("suivant", size: 14).foregroundStyle(secondary)
            }
            .padding(.horizontal, 16).frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Briques

    private func go(_ s: Step) { withAnimation { step = s } }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    /// Gabarit d'écran : illustration optionnelle, titre, sous-titre, contenu, pied fixe.
    private func page<Content: View, Footer: View>(title: String, subtitle: String, centered: Bool = false, illustration: String? = nil,
                                                   @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) -> some View {
        let watchStep = step == .watch
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: centered ? .center : .leading, spacing: 16) {
                    if step == .welcome {
                        PulsingWaves(accent: accent).frame(height: 150).frame(maxWidth: .infinity).padding(.top, 8)
                    } else if step == .account {
                        PrivateProfileCard(accent: accent, surface: surface, border: border, secondary: secondary)
                            .frame(height: 190).frame(maxWidth: .infinity).padding(.top, 28)
                    } else if let illustration, !watchStep {
                        Image(illustration).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 170)
                            .padding(.top, 28)
                    }
                    VStack(alignment: centered ? .center : .leading, spacing: 8) {
                        Text(title).font(.system(size: 28, weight: .bold)).foregroundStyle(ink)
                            .multilineTextAlignment(centered ? .center : .leading).fixedSize(horizontal: false, vertical: true)
                        Text(subtitle).font(.system(size: 16, weight: .regular)).foregroundStyle(secondary)
                            .multilineTextAlignment(centered ? .center : .leading).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                    .padding(.top, illustration == nil || watchStep ? 22 : 0)
                    if watchStep {
                        // Montre sous le titre, sur des cercles discrets (maquette 03).
                        WatchHeartbeat(accent: accent, surface: surface, bg: bg)
                            .scaleEffect(0.84)
                            .frame(height: 200).frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                    content()
                }
                .padding(.horizontal, 24).padding(.bottom, 12)
            }
            VStack(spacing: 8) { footer() }.padding(.horizontal, 24).padding(.bottom, 16)
        }
    }

    private func cardShape(selected: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
            .fill(selected ? selectedSurface : surface)
            .overlay(RoundedRectangle(cornerRadius: cardRadius, style: .continuous).strokeBorder(selected ? accent : border, lineWidth: selected ? 1.5 : 1))
    }

    private func radio(_ on: Bool) -> some View {
        ZStack {
            if on {
                Circle().fill(accent).frame(width: 22, height: 22)
                Circle().fill(bg).frame(width: 9, height: 9)
            } else {
                Circle().strokeBorder(secondary, lineWidth: 2).frame(width: 22, height: 22)
            }
        }
    }

    private func checkBadge(size: CGFloat = 26) -> some View {
        ZStack {
            Circle().fill(accent).frame(width: size, height: size)
            Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(bg)
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            JIcon("ecouteurs", size: 20).foregroundStyle(accent)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(cardShape())
    }

    private func infoLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").font(.system(size: 15)).foregroundStyle(secondary)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func infoCard(system: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: system).font(.system(size: 22)).foregroundStyle(accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(ink)
                Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(cardShape())
    }

    private func chip(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 8) { JIcon(icon, size: 16).foregroundStyle(ink); Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(ink) }
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous).fill(bg.opacity(0.6)).overlay(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous).strokeBorder(border)))
    }

    private func statusLine(ok: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle").font(.system(size: 14)).foregroundStyle(ok ? accent : warning)
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(ok ? accent : warning)
        }
    }

    /// Ligne de vérification : icône, titre, détail, état (✓ / … / !), bouton d'action tant que ce n'est pas prêt.
    private func checkRow(icon: String, title: String, status: SetupState.Status, detail: String?, badge: String? = nil, statusLabel: String? = nil, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                kitIcon(icon, size: 24).foregroundStyle(accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                    if let detail { Text(detail).font(.system(size: 13, weight: .medium)).foregroundStyle(status == .missing ? warning : secondary).fixedSize(horizontal: false, vertical: true) }
                    if let badge {
                        Text(badge).font(.system(size: 13, weight: .bold)).foregroundStyle(bg)
                            .padding(.horizontal, 12).frame(height: 28).background(Capsule().fill(accent)).padding(.top, 4)
                    }
                }
                Spacer()
                VStack(spacing: 4) {
                    switch status {
                    case .ok: checkBadge()
                    case .checking: ProgressView().tint(accent)
                    case .missing:
                        ZStack { Circle().fill(warning).frame(width: 26, height: 26); Text("!").font(.system(size: 15, weight: .heavy)).foregroundStyle(bg) }
                    case .unknown: EmptyView()
                    }
                    if status == .ok, let statusLabel { Text(statusLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(secondary) }
                }
            }
            if let action, status != .ok {
                Button(action: perform) {
                    Text(action).font(.system(size: 14, weight: .bold)).foregroundStyle(bg)
                        .padding(.horizontal, 18).frame(height: 44).background(Capsule().fill(accent))
                }
                .disabled(status == .checking)
            }
        }
        .padding(16)
        .background(cardShape())
    }

    /// Icône du kit onboarding quand elle existe (montre, micro, position, coureur, profil), sinon celle du pack Jeffrey.
    @ViewBuilder
    private func kitIcon(_ name: String, size: CGFloat) -> some View {
        let kit: [String: String] = ["montre": "onb-icon-watch", "micro": "onb-icon-microphone", "parcours": "onb-icon-location", "course": "onb-icon-runner", "profil": "onb-icon-person"]
        if let asset = kit[name] {
            Image(asset).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            JIcon(name, size: size)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(ink).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .focused($focused)
            .font(.system(size: 16, weight: .medium))
            .padding(.horizontal, 16).frame(height: 56)
            .background(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous).fill(surface).overlay(RoundedRectangle(cornerRadius: fieldRadius, style: .continuous).strokeBorder(border)))
    }

    private func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(enabled ? bg : disabledText)
                .frame(maxWidth: .infinity).frame(height: 58)
                .background(Capsule().fill(enabled ? accent : disabledSurface))
        }
        .disabled(!enabled)
    }

    private func outlineButton(_ title: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(accent) }
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(accent)
            }
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(Capsule().strokeBorder(accent, lineWidth: 1.5))
        }
        .disabled(busy)
    }

    private func skipButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(secondary).frame(maxWidth: .infinity).frame(height: 36)
        }
    }
}

/// Symbole Jeffrey encadré d'ondes sonores (arcs de chaque côté, comme la maquette). Les arcs s'allument tour à
/// tour en s'éloignant du symbole, le J bat doucement. Statique si la réduction des animations est active.
private struct PulsingWaves: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wave = 0

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let baseOpacity = 0.7 - Double(i) * 0.18
                let lit = !reduceMotion && wave == i
                Group {
                    WaveArc(side: .left).stroke(accent.opacity(lit ? 1 : baseOpacity), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    WaveArc(side: .right).stroke(accent.opacity(lit ? 1 : baseOpacity), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                .padding(CGFloat(2 - i) * 18)
                .animation(.easeInOut(duration: 0.35), value: wave)
            }
            .frame(width: 190, height: 150)
            // Symbole de la maquette (kit onboarding : point rond séparé, courbe effilée).
            Image("onb-jeffrey-mark").resizable().scaledToFit().frame(height: 66)
        }
        .frame(width: 220, height: 150)
        .onAppear {
            guard !reduceMotion else { return }
            waveLoop()
        }
    }

    private func waveLoop() {
        // L'onde se propage vers l'extérieur : arc 0 (le plus proche du J), puis 1, puis 2, puis repos.
        wave = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { wave = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { wave = 2 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { wave = -1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { waveLoop() }
    }

    /// Arc vertical à gauche ou à droite du symbole (ouverture de 100°), comme les parenthèses de la maquette.
    private struct WaveArc: Shape {
        enum Side { case left, right }
        let side: Side
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            let span = Angle.degrees(50)
            let mid = side == .left ? Angle.degrees(180) : Angle.degrees(0)
            p.addArc(center: center, radius: radius, startAngle: mid - span, endAngle: mid + span, clockwise: false)
            return p
        }
    }
}

/// Apple Watch stylisée (maquette 03) : bracelet et boîtier sombres liserés d'accent, écran noir avec un
/// électrocardiogramme lumineux qui se trace en boucle, cercles discrets en fond.
private struct WatchHeartbeat: View {
    let accent: Color
    let surface: Color
    let bg: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            // Cercles concentriques très discrets
            ForEach(0..<3, id: \.self) { i in
                Circle().strokeBorder(accent.opacity(0.16 - Double(i) * 0.04), lineWidth: 1.5)
                    .frame(width: 150 + CGFloat(i) * 56, height: 150 + CGFloat(i) * 56)
            }
            // Bracelet : deux brins arrondis, sombres, liserés d'accent, légèrement plus étroits que le boîtier
            let strapColor = Color(red: 0x17 / 255, green: 0x1E / 255, blue: 0x18 / 255)
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(strapColor)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.55), lineWidth: 1.2))
                    .frame(width: 72, height: 54)
                Spacer()
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(strapColor)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.55), lineWidth: 1.2))
                    .frame(width: 72, height: 54)
            }
            .frame(height: 230)
            // Boîtier
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(surface)
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(accent.opacity(0.9), lineWidth: 1.5))
                .shadow(color: accent.opacity(0.25), radius: 14)
                .frame(width: 118, height: 158)
            // Couronne
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(accent.opacity(0.8)).frame(width: 5, height: 20).offset(x: 62, y: -14)
            // Écran
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(bg)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(accent.opacity(0.35), lineWidth: 1))
                .frame(width: 100, height: 140)
            // Tracé ECG lumineux
            ZStack {
                ECGShape().stroke(accent.opacity(0.22), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                ECGShape().trim(from: 0, to: reduceMotion ? 1 : progress)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .shadow(color: accent.opacity(0.9), radius: 6)
                if !reduceMotion, progress > 0, progress < 1 {
                    Circle().fill(accent).frame(width: 6, height: 6).shadow(color: accent, radius: 6)
                        .position(ECGShape.point(at: progress, in: CGRect(x: 0, y: 0, width: 80, height: 50)))
                }
            }
            .frame(width: 80, height: 50)
        }
        .frame(width: 280, height: 230)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { progress = 1 }
        }
    }

    /// Un battement : ligne de base, petite bosse, grand pic, creux, retour.
    private struct ECGShape: Shape {
        static let points: [CGPoint] = [
            CGPoint(x: 0, y: 0.5), CGPoint(x: 0.18, y: 0.5), CGPoint(x: 0.26, y: 0.38), CGPoint(x: 0.34, y: 0.5),
            CGPoint(x: 0.42, y: 0.5), CGPoint(x: 0.5, y: 0.02), CGPoint(x: 0.58, y: 0.98), CGPoint(x: 0.66, y: 0.5),
            CGPoint(x: 0.78, y: 0.5), CGPoint(x: 0.84, y: 0.42), CGPoint(x: 0.9, y: 0.5), CGPoint(x: 1, y: 0.5),
        ]
        func path(in rect: CGRect) -> Path {
            var p = Path()
            for (i, pt) in Self.points.enumerated() {
                let point = CGPoint(x: rect.minX + pt.x * rect.width, y: rect.minY + pt.y * rect.height)
                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
            return p
        }
        /// Position le long du tracé (approximation par longueur de segments), pour le point lumineux.
        static func point(at t: CGFloat, in rect: CGRect) -> CGPoint {
            let pts = points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            let lengths = zip(pts, pts.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
            let total = lengths.reduce(0, +)
            var remaining = max(0, min(1, t)) * total
            for (i, len) in lengths.enumerated() {
                if remaining <= len {
                    let f = len == 0 ? 0 : remaining / len
                    return CGPoint(x: pts[i].x + (pts[i + 1].x - pts[i].x) * f, y: pts[i].y + (pts[i + 1].y - pts[i].y) * f)
                }
                remaining -= len
            }
            return pts.last ?? .zero
        }
    }
}

/// Illustration « Ton compte » (maquette 06) : une carte de profil vitrée avec le symbole Jeffrey, deux lignes et un
/// cadenas, posée sur un panneau doux avec un halo.
private struct PrivateProfileCard: View {
    let accent: Color
    let surface: Color
    let border: Color
    let secondary: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [surface.opacity(0.9), surface.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(border.opacity(0.6), lineWidth: 1))
                .frame(width: 300, height: 176)
                .shadow(color: accent.opacity(0.18), radius: 30)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .frame(width: 236, height: 116)
                .overlay(
                    HStack(alignment: .center, spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            Image("onb-jeffrey-mark").resizable().scaledToFit().frame(height: 34)
                            Capsule().fill(secondary.opacity(0.7)).frame(width: 96, height: 7)
                            Capsule().fill(secondary.opacity(0.5)).frame(width: 64, height: 7)
                        }
                        Spacer()
                        Image(systemName: "lock").font(.system(size: 30, weight: .regular)).foregroundStyle(accent.opacity(0.85))
                    }
                    .padding(.horizontal, 22)
                )
        }
    }
}
