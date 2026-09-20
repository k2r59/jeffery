import SwiftUI

/// Onglet Jeffrey : quatre réglages qui comptent en courant, le reste derrière « Avancé ».
struct JeffreyView: View {
    @EnvironmentObject private var coach: CoachSession
    @AppStorage(Prefs.presence) private var presence: String = "present"
    @AppStorage(Prefs.voice) private var voice: String = "marin"
    @AppStorage(Prefs.duckMusic) private var duckMusic: Bool = true
    @AppStorage(Prefs.micSource) private var micSource: String = "headset"
    @AppStorage(Prefs.mode) private var modeRaw: String = CaptureMode.companion.rawValue
    @AppStorage(Prefs.userName) private var userName: String = ""
    @State private var showAdvanced = false
    @State private var showAccess = false
    @AppStorage(Prefs.setupVersion) private var setupVersion: Int = 0
    @ObservedObject private var account = AccountStore.shared
    @StateObject private var preview = VoicePreview()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        JeffreyHeader()
                        HStack { Spacer(); JeffreyMark(size: 72); Spacer() }
                        Text("À ton rythme.").font(.display(30, weight: .black)).foregroundStyle(.white)

                        card("Il parle…", "Présent : un point toutes les 2 minutes. Discret : toutes les 4, et seulement l'essentiel.") {
                            HStack(spacing: 4) {
                                segment("Discret", selected: presence == "discreet") { presence = "discreet" }
                                segment("Présent", selected: presence == "present") { presence = "present" }
                            }
                            .padding(4).background(Capsule().fill(Theme.surfaceRaised))
                        }

                        card("Sa voix", nil) {
                            HStack(spacing: 10) {
                                Picker("Voix", selection: $voice) {
                                    ForEach(Prefs.voices, id: \.self) { Text($0.capitalized).tag($0) }
                                }
                                .pickerStyle(.menu).tint(.white).labelsHidden()
                                Spacer()
                                Button { preview.play(voice: voice, name: userName) } label: {
                                    HStack(spacing: 6) {
                                        if preview.isLoading { ProgressView().tint(Theme.background).scaleEffect(0.8) } else { JIcon(preview.isPlaying ? "volume" : "lecture", size: 14) }
                                        Text(preview.isLoading ? "Jeffrey arrive…" : "Écouter")
                                    }
                                    .font(.system(size: 13, weight: .black)).foregroundStyle(Theme.background)
                                    .padding(.horizontal, 14).frame(height: 38)
                                    .background(Capsule().fill(Theme.citron))
                                }
                                .disabled(preview.isLoading || coach.phase != .idle)
                            }
                            if let err = preview.error { Text(err).font(.caption).foregroundStyle(Theme.pulse) }
                        }

                        card("Musique et micro", micSource == "headset"
                             ? "Micro des écouteurs : Jeffrey t'entend bien, la musique passe en qualité téléphone pendant la séance."
                             : "Micro de l'iPhone : musique en pleine qualité, parle un peu plus fort.") {
                            Toggle(isOn: $duckMusic) {
                                HStack(spacing: 8) { JIcon("musique", size: 18); Text("Baisser la musique quand il parle") }
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            }
                            .tint(Theme.lime)
                            HStack(spacing: 4) {
                                segment("Micro écouteurs", selected: micSource == "headset") { micSource = "headset" }
                                segment("Micro iPhone", selected: micSource == "iphone") { micSource = "iphone" }
                            }
                            .padding(4).background(Capsule().fill(Theme.surfaceRaised))
                        }

                        card("Ta montre", modeRaw == CaptureMode.companion.rawValue
                             ? "Tu lances ta séance dans l'app Exercice, Jeffrey suit à côté."
                             : "Jeffrey enregistre lui-même la séance dans Santé (données plus fréquentes).") {
                            HStack {
                                JIcon("montre", size: 18).foregroundStyle(Theme.creme)
                                Text(coach.connectivity.linkLabel)
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                Spacer()
                                Circle().fill(coach.connectivity.watchConnected ? Theme.lime : Theme.alerte).frame(width: 8, height: 8)
                            }
                            if account.user?.isAdmin == true {
                                Text(coach.connectivity.diagnostic).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted)
                            }
                            HStack(spacing: 4) {
                                segment("Avec l'app Exercice", selected: modeRaw == CaptureMode.companion.rawValue) { modeRaw = CaptureMode.companion.rawValue }
                                segment("Par Jeffrey", selected: modeRaw == CaptureMode.owned.rawValue) { modeRaw = CaptureMode.owned.rawValue }
                            }
                            .padding(4).background(Capsule().fill(Theme.surfaceRaised))
                        }

                        Button { showAccess = true } label: {
                            HStack {
                                HStack(spacing: 8) { JIcon("profil", size: 18); Text(account.user?.isAdmin == true ? "Accès et utilisateurs" : "Mon compte") }
                                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                Spacer()
                                Text(account.user.map { $0.roleLabel } ?? "pas connecté").font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(account.user?.canUse == true ? Theme.lime : Theme.muted)
                                JIcon("suivant", size: 14).foregroundStyle(Theme.muted)
                            }
                            .card()
                        }
                        .accessibilityIdentifier("Mon compte")

                        Button { setupVersion = 0 } label: {
                            HStack {
                                HStack(spacing: 8) { JIcon("valider", size: 18); Text("Refaire la configuration") }
                                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                Spacer()
                                Text("montre, micro, position, clé, tour d'essai").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                                JIcon("suivant", size: 14).foregroundStyle(Theme.muted)
                            }
                            .card()
                        }
                        .accessibilityIdentifier("Refaire la configuration")

                        // Réglages avancés (clé, modèles, prompt) : administrateur seulement.
                        if account.user?.isAdmin == true {
                        Button { showAdvanced = true } label: {
                            HStack {
                                HStack(spacing: 8) { JIcon("reglages", size: 18); Text("Avancé") }
                                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                Spacer()
                                Text("clé, modèles, micro, voix Apple, prompt").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                                JIcon("suivant", size: 14).foregroundStyle(Theme.muted)
                            }
                            .card()
                        }
                        .accessibilityIdentifier("Avancé")
                        }
                    }
                    .padding(18)
                    .padding(.bottom, 70)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAdvanced) { SettingsView() }
            .sheet(isPresented: $showAccess) { AccessView() }
        }
    }

    private func card<Content: View>(_ title: String, _ hint: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.creme)
            content()
            if let hint { Text(hint).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted) }
        }
        .card()
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .bold))
                .foregroundStyle(selected ? Theme.background : .white)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(Capsule().fill(selected ? Theme.lime : .clear))
        }
    }
}
