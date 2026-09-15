import SwiftUI

struct JeffreyView: View {
    @EnvironmentObject private var coach: CoachSession
    @AppStorage(Prefs.presence) private var presence: String = "present"
    @AppStorage(Prefs.voice) private var voice: String = "marin"
    @AppStorage(Prefs.autoCues) private var autoCues: Bool = true
    @AppStorage(Prefs.goalCues) private var goalCues: Bool = true
    @AppStorage(Prefs.mode) private var modeRaw: String = CaptureMode.companion.rawValue
    @AppStorage(Prefs.userName) private var userName: String = ""
    @State private var showAdvanced = false
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
                        Text("Toujours là pour t'écouter, te motiver et t'aider à progresser.")
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)

                        section("Présence du coach") {
                            HStack(spacing: 4) {
                                segment("Discret", selected: presence == "discreet") { presence = "discreet" }
                                segment("Présent", selected: presence == "present") { presence = "present" }
                            }
                            .padding(4).background(Capsule().fill(Theme.surfaceRaised))
                        }
                        section("Voix du coach") {
                            HStack(spacing: 10) {
                                Picker("Voix", selection: $voice) {
                                    ForEach(Prefs.voices, id: \.self) { Text($0.capitalized).tag($0) }
                                }
                                .pickerStyle(.menu).tint(.white).labelsHidden()
                                Spacer()
                                Button {
                                    preview.play(voice: voice, name: userName)
                                } label: {
                                    HStack(spacing: 6) {
                                        if preview.isLoading {
                                            ProgressView().tint(Theme.background).scaleEffect(0.8)
                                        } else {
                                            JIcon(preview.isPlaying ? "volume" : "lecture", size: 14)
                                        }
                                        Text(preview.isLoading ? "Jeffrey arrive…" : "Écouter")
                                    }
                                    .font(.system(size: 13, weight: .black)).foregroundStyle(Theme.background)
                                    .padding(.horizontal, 14).frame(height: 38)
                                    .background(Capsule().fill(Theme.lime))
                                }
                                .disabled(preview.isLoading || coach.phase != .idle)
                            }
                            if let err = preview.error {
                                Text(err).font(.caption).foregroundStyle(Theme.pulse)
                            }
                        }
                        section("Pendant la séance") {
                            toggleRow("Encouragements", "valider", $autoCues)
                            toggleRow("Points sur l'objectif", "objectif", $goalCues)
                        }
                        section("Apple Watch") {
                            HStack {
                                JIcon("montre", size: 18).foregroundStyle(Theme.creme)
                                Text(coach.connectivity.isWatchAppInstalled ? (coach.connectivity.isReachable ? "Connectée" : "Installée, hors de portée") : "App montre non installée")
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                Spacer()
                                Circle().fill(coach.connectivity.isReachable ? Theme.lime : Theme.muted).frame(width: 8, height: 8)
                            }
                            Picker("Mode", selection: $modeRaw) {
                                Text("Suivre l'app Exercice").tag(CaptureMode.companion.rawValue)
                                Text("Séance par Jeffrey").tag(CaptureMode.owned.rawValue)
                            }
                            .pickerStyle(.segmented)
                        }
                        JeffreyBubble(text: "Tu peux toujours me demander de parler moins.")
                        Button { showAdvanced = true } label: {
                            HStack {
                                HStack(spacing: 8) { JIcon("reglages", size: 18); Text("Profil, clé API, micro, prompt…") }
                                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                Spacer()
                                JIcon("suivant", size: 14).foregroundStyle(Theme.muted)
                            }
                            .card()
                        }
                    }
                    .padding(18)
                    .padding(.bottom, 70)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAdvanced) { SettingsView() }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
            content()
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

    private func toggleRow(_ title: String, _ icon: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            HStack(spacing: 8) { JIcon(icon, size: 18); Text(title) }.font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
        }
        .tint(Theme.lime)
    }
}
