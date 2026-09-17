import SwiftUI
import MapKit

struct SessionEndView: View {
    @Environment(\.dismiss) private var dismiss
    @State var summary: SessionSummary
    @AppStorage(Prefs.userName) private var userName: String = ""
    @State private var route: LocalRoute?
    @State private var analyzing = false
    @State private var analysisError: String?

    private var coordinates: [CLLocationCoordinate2D] {
        route?.locations.filter { $0.horizontalAccuracy < 60 }.map(\.coordinate) ?? []
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            RadialGradient(colors: [Theme.lime.opacity(0.22), .clear], center: .top, startRadius: 0, endRadius: 380).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    JeffreyMark(size: 56).padding(.top, 8)
                    VStack(spacing: 6) {
                        (Text("Bien joué, ") + Text(userName.isEmpty ? "champion" : userName).foregroundStyle(Theme.lime) + Text("."))
                            .font(.display(30, weight: .black)).foregroundStyle(.white)
                        Text("Chaque sortie compte.").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.muted)
                        Text(Formatters.elapsed(summary.elapsed))
                            .font(.display(64, weight: .black).monospacedDigit()).foregroundStyle(.white)
                        HStack(spacing: 14) {
                            if let d = summary.distance { Text(Formatters.distance(d)) }
                            if let hr = summary.averageHeartRate { Text("\(Int(hr)) bpm moy.") }
                            if let m = summary.maxHeartRate { Text("\(Int(m)) max") }
                        }
                        .font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    if (summary.ascent ?? 0) >= 5 || (summary.walkingSeconds ?? 0) > 30 {
                        HStack(spacing: 14) {
                            if let r = summary.runningSeconds, r > 30 { Label(Formatters.elapsed(r), systemImage: "figure.run") }
                            if let w = summary.walkingSeconds, w > 30 { Label(Formatters.elapsed(w), systemImage: "figure.walk") }
                            if let a = summary.ascent, a >= 5 { Label("D+ \(Int(a)) m", systemImage: "arrow.up.right") }
                        }
                        .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    if coordinates.count >= 2 {
                        Map {
                            MapPolyline(coordinates: coordinates)
                                .stroke(Theme.lime, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        }
                        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    if let g = summary.goalLabel {
                        HStack(spacing: 8) {
                            JIcon(summary.goalReached == true ? "valider" : "objectif", size: 18)
                                .foregroundStyle(summary.goalReached == true ? Theme.lime : Theme.muted)
                            Text("Ton objectif · \(g) · \(summary.goalReached == true ? "Atteint" : "Pas cette fois, et c'est très bien")")
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            Spacer()
                        }
                        .card()
                    }
                    VStack(spacing: 14) {
                        Text("Comment tu te sens ?").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        HStack(spacing: 22) {
                            ForEach(Feeling.allCases) { f in
                                Button {
                                    summary.feeling = f
                                    SessionSummary.upsert(summary)
                                } label: {
                                    VStack(spacing: 8) {
                                        JIcon(f.icon, size: 30)
                                            .foregroundStyle(summary.feeling == f ? Theme.background : Theme.muted)
                                            .frame(width: 58, height: 58)
                                            .background(Circle().fill(summary.feeling == f ? Theme.lime : Theme.surfaceRaised))
                                        Text(f.label).font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(summary.feeling == f ? Theme.lime : Theme.muted)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                    analysisCard
                    if let line = summary.lastCoachLine, !line.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            JeffreyMark(size: 22)
                            Text(line).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                        }
                        .card()
                    }
                    Button {
                        SessionSummary.upsert(summary)
                        dismiss()
                    } label: {
                        Text("Terminer le bilan")
                            .font(.display(16, weight: .black)).foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity).frame(height: 56)
                            .background(Capsule().fill(Theme.startGradient))
                    }
                    .padding(.top, 4)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            route = LocalRoute.matching(start: summary.date, end: summary.date.addingTimeInterval(summary.elapsed + 60))
            SessionSummary.upsert(summary)
            if summary.analysis == nil { runAnalysis() }
        }
    }

    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                JeffreyMark(state: analyzing ? .speaking : .available, size: 24)
                Text("LE REGARD DE JEFFREY").font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
                Spacer()
                if !analyzing, summary.analysis != nil {
                    Button { runAnalysis() } label: { JIcon("actualiser", size: 14).foregroundStyle(Theme.muted) }
                }
            }
            if analyzing {
                Text("Jeffrey regarde ta séance, ta forme et tes dernières sorties…")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)
            } else if let a = summary.analysis {
                Text(a).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.creme)
                if let advice = summary.advice, !advice.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        JIcon("objectif", size: 16).foregroundStyle(Theme.citron)
                        Text("Pour la prochaine : \(advice)").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.citron)
                    }
                }
                if let c = summary.caution, !c.isEmpty, c.lowercased() != "null" {
                    HStack(alignment: .top, spacing: 8) {
                        JIcon("information", size: 16).foregroundStyle(Theme.alerte)
                        Text(c).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.alerte)
                    }
                }
            } else if let e = analysisError {
                Text("Bilan indisponible : \(e)").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.alerte)
                Button("Réessayer") { runAnalysis() }.font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.citron)
            }
        }
        .card()
    }

    private func runAnalysis() {
        guard !analyzing else { return }
        analyzing = true
        analysisError = nil
        Task {
            let config = CoachConfig.load()
            guard !config.apiKey.isEmpty else { analysisError = "clé API manquante"; analyzing = false; return }
            let health = await SessionAnalyst.healthContext()
            let dossier = SessionAnalyst.dossier(summary: summary, config: config, health: health, zones: summary.zoneCounts ?? [])
            do {
                let model = UserDefaults.standard.string(forKey: Prefs.analysisModel) ?? "gpt-5-mini"
                let r = try await SessionAnalyst.analyze(dossier: dossier, apiKey: config.apiKey, model: model, userName: userName)
                summary.analysis = r.analysis
                summary.advice = r.advice
                summary.caution = r.caution
                SessionSummary.upsert(summary)
                // Mémoire longue : ce que la conversation apprend de durable sur la personne.
                if summary.memoryUpdated != true, let lines = summary.transcriptExcerpt, lines.contains(where: { $0.hasPrefix("Lui :") }) {
                    let memory = JeffreyMemory.shared
                    let line = "\(summary.kind.coachLabel), \(Formatters.elapsed(summary.elapsed))\(summary.feeling.map { ", ressenti \($0.coachLabel)" } ?? "")"
                    if let notes = try? await SessionAnalyst.updateMemory(transcript: lines, existing: memory.notes.map(\.text), summaryLine: line, apiKey: config.apiKey, model: model) {
                        memory.replace(with: notes)
                        summary.memoryUpdated = true
                        SessionSummary.upsert(summary)
                    }
                }
            } catch {
                analysisError = error.localizedDescription
            }
            analyzing = false
        }
    }
}
