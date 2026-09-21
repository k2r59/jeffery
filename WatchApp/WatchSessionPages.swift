import SwiftUI
import WatchKit

/// Les vues de la maquette « Au rythme du poignet » : Séance, Effort, Intervalles, Coach vocal, Pause, Bilan.
/// Même grammaire partout : en-tête en petites capitales sauge sur la ligne de l'heure système, un grand chiffre
/// citron (ou crème à l'arrêt), des libellés sauge, fond noir, pas de cartes.
enum WatchUI {
    static let citron = JeffreyPalette.citron
    static let creme = JeffreyPalette.creme
    static let sauge = JeffreyPalette.sauge
    static let surface = Color(white: 0.16)
    static let alerte = JeffreyPalette.alerte

    /// En-tête : titre à gauche, place laissée à droite pour l'heure système.
    static func header(_ title: String, color: Color = sauge) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 24)
            .padding(.trailing, 62)
    }

    /// Mise en page commune : la page ignore la zone sûre du haut pour poser son en-tête sur la ligne de l'heure.
    struct Chrome: ViewModifier {
        func body(content: Content) -> some View {
            content.padding(.horizontal, 8).padding(.top, 12).ignoresSafeArea(edges: .top)
        }
    }

    static func km(_ meters: Double?) -> String {
        guard let m = meters else { return "--" }
        return String(format: "%.2f", m / 1000).replacingOccurrences(of: ".", with: ",")
    }

    static func big(_ text: String, color: Color = citron, size: CGFloat = 46) -> some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.6)
    }

    static func label(_ text: String, size: CGFloat = 13) -> some View {
        Text(text).font(.system(size: size, weight: .medium, design: .rounded)).foregroundStyle(sauge)
    }

    /// Chiffre + unité, comme « 1,82 / km ».
    static func metric(_ value: String, _ unit: String, size: CGFloat = 26) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(creme)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(unit).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(sauge)
        }
        .frame(maxWidth: .infinity)
    }

    static func divider() -> some View {
        Rectangle().fill(creme.opacity(0.18)).frame(width: 1, height: 34)
    }

    /// Bouton pilule plein (citron) ou contour.
    static func pill(_ title: String, icon: String? = nil, filled: Bool, tint: Color = citron, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { JIcon(icon, size: 13) }
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(filled ? Color.black : tint)
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(
                Capsule().fill(filled ? tint : Color.clear)
                    .overlay(Capsule().stroke(filled ? Color.clear : tint.opacity(0.6), lineWidth: 1.2))
            )
        }
        .buttonStyle(.plain)
    }

    /// Bouton « chip » sombre (page Jeffrey).
    static func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(creme)
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(Capsule().fill(surface))
        }
        .buttonStyle(.plain)
    }

    static func zoneName(_ z: Int) -> String {
        switch z { case 1: return "Récupération"; case 2: return "Endurance"; case 3: return "Tempo"; case 4: return "Seuil"; default: return "Maximal" }
    }

    static func pace(_ secPerKm: Double?) -> String {
        guard let p = secPerKm, p > 0, p < 3600 else { return "--" }
        let m = Int(p) / 60, s = Int(p) % 60
        return String(format: "%d'%02d\"", m, s)
    }
}

// MARK: 01 / Séance

struct WatchSessionPage: View {
    let mirror: CoachMirror
    let snapshot: MetricsSnapshot
    let elapsed: TimeInterval
    /// Une ligne d'information de Jeffrey (montée, fantôme, objectif) à la place du cœur quand elle existe.
    var banner: String?

    var body: some View {
        let hr = snapshot.heartRate ?? mirror.heartRate
        let distance = snapshot.distance ?? mirror.distance
        VStack(spacing: 0) {
            WatchUI.header(mirror.kind.label)
            Spacer(minLength: 2)
            WatchUI.big(Formatters.elapsed(elapsed), color: mirror.paused ? WatchUI.creme : WatchUI.citron)
            WatchUI.label("Durée")
            Spacer(minLength: 8)
            if mirror.kind.usesDistance {
                HStack(spacing: 0) {
                    WatchUI.metric(WatchUI.km(distance), "km")
                    WatchUI.divider()
                    WatchUI.metric(WatchUI.pace(mirror.paceSecPerKm), "/km")
                }
            } else {
                HStack(spacing: 0) {
                    WatchUI.metric(snapshot.activeEnergy.map { "\(Int($0))" } ?? "--", "kcal")
                    WatchUI.divider()
                    WatchUI.metric(mirror.averageHeartRate.map { "\(Int($0))" } ?? "--", "bpm moy.")
                }
            }
            Spacer(minLength: 8)
            if let banner {
                Text(banner).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(WatchUI.citron)
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
            } else {
                HStack(spacing: 6) {
                    HeartBeat(bpm: hr)
                    Text(hr.map { "\(Int($0)) bpm" } ?? "-- bpm").font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(WatchUI.creme)
                    if let z = mirror.zone { Text("· Z\(z)").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(WatchUI.creme) }
                }
            }
            Spacer(minLength: 10)
        }
        .modifier(WatchUI.Chrome())
    }
}

/// Cœur citron qui bat au rythme mesuré (immobile sans mesure).
struct HeartBeat: View {
    var bpm: Double?
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: bpm == nil)) { ctx in
            let period = 60.0 / max(40, min(200, bpm ?? 60))
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            let scale = bpm == nil ? 1 : 1 + 0.18 * max(0, sin(t * .pi * 2)) * (t < 0.5 ? 1 : 0)
            Image(systemName: "heart.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(WatchUI.citron).scaleEffect(scale)
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: 02 / Effort

struct WatchEffortPage: View {
    let mirror: CoachMirror
    let snapshot: MetricsSnapshot

    var body: some View {
        let hr = snapshot.heartRate ?? mirror.heartRate
        let zone = mirror.zone
        let target = mirror.scene?.kind == .zone ? mirror.scene?.zone : nil
        VStack(spacing: 0) {
            WatchUI.header("Mon effort")
            Spacer(minLength: 2)
            WatchUI.big(hr.map { "\(Int($0))" } ?? "--")
            WatchUI.label("bpm")
            Spacer(minLength: 10)
            ZoneBar(zone: zone, target: target)
            Spacer(minLength: 8)
            if let z = zone {
                Text("Zone \(z)").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(WatchUI.citron)
                Text(WatchUI.zoneName(z)).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(WatchUI.creme)
            } else {
                Text("En attente du cœur").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(WatchUI.creme)
            }
            Text(advice(zone: zone, target: target)).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(WatchUI.sauge)
                .padding(.top, 2).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 8)
        }
        .modifier(WatchUI.Chrome())
    }

    private func advice(zone: Int?, target: Int?) -> String {
        guard let zone else { return "La montre cherche ton pouls." }
        if let target {
            if zone == target { return "Reste à ce rythme." }
            return zone < target ? "Accélère un peu (cible Z\(target))." : "Lève le pied (cible Z\(target))."
        }
        switch zone { case 1: return "Tranquille, tu récupères."; case 2: return "Reste à ce rythme."; case 3: return "Bon tempo, respire large."; case 4: return "Effort soutenu, tiens bon."; default: return "Maximal : pas longtemps." }
    }
}

/// Cinq segments Z1…Z5 ; le courant en citron, la cible cerclée, un repère au-dessus du courant.
struct ZoneBar: View {
    var zone: Int?
    var target: Int?

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let w = (geo.size.width - 4 * 4) / 5
                if let zone {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 8)).foregroundStyle(WatchUI.creme)
                        .position(x: w * (CGFloat(zone) - 0.5) + 4 * CGFloat(zone - 1), y: 4)
                }
            }
            .frame(height: 8)
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { z in
                    Capsule()
                        .fill(z == zone ? WatchUI.citron : WatchUI.sauge.opacity(0.35))
                        .overlay(Capsule().stroke(z == target && z != zone ? WatchUI.citron : Color.clear, lineWidth: 1.5))
                        .frame(height: z == zone ? 12 : 9)
                }
            }
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { z in
                    Text("Z\(z)").font(.system(size: 10, weight: z == zone ? .bold : .medium, design: .rounded))
                        .foregroundStyle(z == zone ? WatchUI.citron : WatchUI.sauge).frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: 03 / Intervalles

struct WatchIntervalPage: View {
    let mirror: CoachMirror
    let now: Date

    var body: some View {
        let scene = mirror.scene
        let end = scene?.endsAt ?? mirror.timerEndsAt
        let start = scene?.startsAt
        let remaining = end.map { max(0, $0.timeIntervalSince(now)) } ?? 0
        let total = (start.flatMap { s in end.map { $0.timeIntervalSince(s) } }) ?? 0
        let progress = total > 0 ? min(1, max(0, 1 - remaining / total)) : 0
        let title = scene?.title ?? mirror.timerLabel ?? "Chrono"
        let isRest = scene?.phase == "rest"
        VStack(spacing: 0) {
            WatchUI.header(title, color: isRest ? WatchUI.sauge : WatchUI.citron)
            Spacer(minLength: 2)
            ZStack {
                Circle().stroke(WatchUI.creme.opacity(0.12), lineWidth: 9)
                Circle().trim(from: 0, to: progress)
                    .stroke(isRest ? WatchUI.sauge : WatchUI.citron, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
                VStack(spacing: 0) {
                    Text(clock(remaining)).font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(WatchUI.creme)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    WatchUI.label("restantes", size: 12)
                }
            }
            .frame(width: 112, height: 112)
            Spacer(minLength: 6)
            if let step = mirror.planStep {
                Text(step).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(WatchUI.creme)
            }
            if let next = mirror.planNext {
                Text("Ensuite : \(next)").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(WatchUI.sauge)
                    .lineLimit(1).minimumScaleFactor(0.8)
            } else if let sub = scene?.subtitle {
                Text(sub).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(WatchUI.sauge).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
        }
        .modifier(WatchUI.Chrome())
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: 04 / Coach vocal

struct WatchCoachPage: View {
    let mirror: CoachMirror
    var phoneReachable: Bool
    var onAsk: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            WatchUI.header("Jeffrey")
            Spacer(minLength: 2)
            JeffreyVoiceView(speaking: mirror.coachSpeaking, size: 30)
            Text(state).font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(WatchUI.creme)
                .lineLimit(1).minimumScaleFactor(0.7).padding(.top, 4)
            VoiceBars(active: mirror.coachSpeaking || mirror.userSpeaking).frame(height: 18).padding(.top, 4)
            Spacer(minLength: 8)
            WatchUI.chip("Comment je vais ?") { onAsk("Comment je vais ? Donne-moi ton avis sur mon effort en une phrase.") }
            WatchUI.chip("Répète le conseil") { onAsk("Répète ton dernier conseil, en une phrase.") }.padding(.top, 6)
            Spacer(minLength: 6)
        }
        .modifier(WatchUI.Chrome())
    }

    // La montre n'affiche pas les phrases de Jeffrey (choix du 21/09) : il les dit, la montre montre son état.

    private var state: String {
        if !phoneReachable { return "iPhone hors de portée" }
        switch mirror.phase {
        case "connecting": return "J'arrive…"
        case "foreground": return "Ouvre l'iPhone"
        case "ending": return "Débrief"
        case "live":
            return mirror.coachSpeaking ? "Je te parle" : "Je t'écoute"
        default: return "Prêt"
        }
    }
}

/// Barres de niveau symétriques, animées quand quelqu'un parle.
struct VoiceBars: View {
    var active: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<19, id: \.self) { i in
                    let d = abs(Double(i) - 9) / 9
                    let base = 0.25 + (1 - d) * 0.75
                    let wave = active ? 0.55 + 0.45 * sin(t * 9 + Double(i) * 0.9) : 0.35
                    Capsule().fill(d < 0.35 ? WatchUI.citron : WatchUI.sauge.opacity(0.7))
                        .frame(width: 2.5, height: max(3, 18 * base * wave))
                }
            }
        }
    }
}

// MARK: 05 / Pause

struct WatchPausePage: View {
    let elapsed: TimeInterval
    var onResume: () -> Void
    var onEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WatchUI.header("En pause")
            Spacer(minLength: 2)
            WatchUI.big(Formatters.elapsed(elapsed), color: WatchUI.creme, size: 44)
            Spacer(minLength: 10)
            WatchUI.pill("Reprendre", icon: "lecture", filled: true, action: onResume)
            WatchUI.pill("Terminer", icon: "arreter", filled: false, tint: WatchUI.alerte, action: onEnd).padding(.top, 8)
            Spacer(minLength: 6)
        }
        .modifier(WatchUI.Chrome())
    }
}

/// Contrôles pendant la séance (page de gauche, comme l'app Exercice) : Pause et Terminer.
struct WatchControlsPage: View {
    var phoneReachable: Bool
    var onPause: () -> Void
    var onEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WatchUI.header("Séance")
            Spacer(minLength: 6)
            WatchUI.pill("Pause", icon: "pause", filled: true, action: onPause)
            WatchUI.pill("Terminer", icon: "arreter", filled: false, tint: WatchUI.alerte, action: onEnd).padding(.top, 8)
            Spacer(minLength: 6)
            Text(phoneReachable ? "Commandes envoyées à l'iPhone" : "iPhone hors de portée")
                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(WatchUI.sauge)
            Spacer(minLength: 4)
        }
        .modifier(WatchUI.Chrome())
    }
}

// MARK: 06 / Bilan

struct WatchSummaryPage: View {
    let elapsed: TimeInterval
    let distance: Double?
    let averageHeartRate: Double?
    let usesDistance: Bool
    let energy: Double?
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WatchUI.header("Bien joué", color: WatchUI.citron)
            Spacer(minLength: 2)
            WatchUI.big(Formatters.elapsed(elapsed), color: WatchUI.creme)
            WatchUI.label("Durée")
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                if usesDistance {
                    WatchUI.metric(WatchUI.km(distance), "km")
                } else {
                    WatchUI.metric(energy.map { "\(Int($0))" } ?? "--", "kcal")
                }
                WatchUI.divider()
                VStack(spacing: 0) {
                    WatchUI.metric(averageHeartRate.map { "\(Int($0))" } ?? "--", "bpm")
                    WatchUI.label("Moyenne", size: 11)
                }
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 8)
            WatchUI.chip("Voir sur iPhone", action: onDismiss)
            Spacer(minLength: 6)
        }
        .modifier(WatchUI.Chrome())
    }
}
