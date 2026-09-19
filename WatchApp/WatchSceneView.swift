import SwiftUI
import WatchKit

/// Écran plein piloté par Jeffrey : compte à rebours, fractionné, zone cible, allure cible, message, montée, fantôme, fête.
struct WatchSceneView: View {
    let scene: WatchScene
    let heartRate: Double?
    let elapsed: TimeInterval

    private let citron = JeffreyPalette.citron
    private let creme = JeffreyPalette.creme
    private let sauge = JeffreyPalette.sauge
    private let surface = JeffreyPalette.surface
    private let alerte = JeffreyPalette.alerte

    /// Échelle selon la montre : 1 à partir de 45 mm, un peu moins sur 40/41/42 mm (gabarit dessiné pour 223 pt de haut).
    private var k: CGFloat { min(1, max(0.82, WKInterfaceDevice.current().screenBounds.height / 223)) }
    /// Marge basse (bord arrondi de l'écran).
    private let dotsInset: CGFloat = 6

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch scene.kind {
        case .countdown, .interval: framed { countdown(now: now) }
        case .zone: framed { zone }
        case .pace: framed { pace }
        case .message: message
        case .climb: framed { climb }
        case .ghost: framed { ghost }
        case .celebration: celebration
        }
    }

    /// Grille commune : tout l'écran. Le titre partage la ligne de l'heure système (à gauche, comme l'app Exercice),
    /// le reste de la hauteur va au visuel et aux infos.
    private func framed<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 10)
            .padding(.horizontal, 2)
            .padding(.bottom, dotsInset)
            .ignoresSafeArea(edges: [.horizontal, .top])
    }

    /// Espace élastique entre les étages d'une scène.
    private var gap: some View { Spacer(minLength: 4 * k) }

    // MARK: Compte à rebours / fractionné

    private func countdown(now: Date) -> some View {
        let end = scene.endsAt ?? now
        let start = scene.startsAt ?? now
        let total = max(1, end.timeIntervalSince(start))
        let remaining = max(0, end.timeIntervalSince(now))
        let fraction = min(1, max(0, remaining / total))
        let rest = scene.phase == "rest"
        let color: Color = scene.kind == .countdown ? citron : (rest ? sauge : alerte)
        // Anneau contenu : le titre au-dessus et la suite en dessous restent lisibles, sans coller à l'anneau.
        return VStack(spacing: 0) {
            header(scene.title, color: color)
            gap
            ZStack {
                Circle().stroke(surface, lineWidth: 8)
                Circle().trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: fraction)
                VStack(spacing: 0) {
                    Text(remaining >= 60 ? Formatters.elapsed(remaining) : "\(Int(remaining.rounded(.up)))")
                        .font(.system(size: (remaining >= 60 ? 30 : 40) * k, weight: .heavy).monospacedDigit()).foregroundStyle(creme)
                    Text(remaining >= 60 ? "restantes" : "secondes").font(.system(size: 11 * k, weight: .semibold)).foregroundStyle(sauge)
                }
            }
            .frame(width: 114 * k, height: 114 * k)
            gap
            VStack(spacing: 3) {
                if let hr = heartRate { Text("\(Int(hr)) bpm").font(.system(size: 15 * k, weight: .bold).monospacedDigit()).foregroundStyle(creme) }
                Text(scene.subtitle ?? scene.caption ?? " ").font(.system(size: 13 * k, weight: .semibold)).foregroundStyle(sauge)
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.85)
            }
        }
    }

    // MARK: Zone cardiaque cible

    private var zone: some View {
        let low = scene.low ?? 0, high = scene.high ?? 1
        let hr = heartRate ?? 0
        let span = max(1, high - low)
        // La jauge couvre de low − 1 zone à high + 1 zone : la cible occupe le tiers central.
        let gMin = low - span, gMax = high + span
        let pos = min(1, max(0, (hr - gMin) / (gMax - gMin)))
        let inside = hr >= low && hr <= high
        let status = heartRate == nil ? "en attente du cœur" : (inside ? "dans la zone ✓" : (hr < low ? "accélère un peu" : "relâche"))
        let size = 124 * k
        return VStack(spacing: 0) {
            header(scene.title, color: citron)
            gap
            ZStack {
                Circle().trim(from: 0.12, to: 0.88).stroke(surface, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(90))
                Circle().trim(from: 0.12 + 0.76 / 3, to: 0.12 + 0.76 * 2 / 3).stroke(citron, lineWidth: 10).rotationEffect(.degrees(90))
                Circle().trim(from: 0.12 + 0.76 * 2 / 3, to: 0.88).stroke(alerte.opacity(0.7), style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(90))
                if heartRate != nil {
                    Circle().fill(creme).frame(width: 13, height: 13).overlay(Circle().stroke(Color.black, lineWidth: 3))
                        .offset(y: -size / 2)
                        .rotationEffect(.degrees(-137 + 274 * pos))
                        .animation(.easeInOut(duration: 0.8), value: pos)
                }
                VStack(spacing: 0) {
                    Text(heartRate.map { "\(Int($0))" } ?? "--").font(.system(size: 36 * k, weight: .heavy).monospacedDigit()).foregroundStyle(creme)
                    Text("bpm").font(.system(size: 10 * k, weight: .semibold)).foregroundStyle(sauge)
                }
            }
            .frame(width: size, height: size)
            gap
            VStack(spacing: 3) {
                Text(status).font(.system(size: 14 * k, weight: .bold)).foregroundStyle(inside ? citron : (hr > high ? alerte : creme))
                Text(scene.subtitle ?? "").font(.system(size: 12 * k, weight: .semibold)).foregroundStyle(sauge)
            }
        }
    }

    // MARK: Allure cible

    private var pace: some View {
        let low = scene.low ?? 0, high = scene.high ?? 0
        let target = (low + high) / 2
        let current = scene.value
        let delta = current.map { $0 - target }
        let status: String = {
            guard let d = delta else { return "en attente de l'allure" }
            if abs(d) <= (high - low) / 2 { return "dans le bon tempo ✓" }
            return d < 0 ? "▲ trop vite · \(Int(abs(d))) s" : "▼ trop lent · \(Int(d)) s"
        }()
        let ok = delta.map { abs($0) <= (high - low) / 2 } ?? false
        let pos = current.map { min(1, max(0, ($0 - (target - 90)) / 180)) } ?? 0.5
        return VStack(spacing: 0) {
            header(scene.title, color: citron)
            gap
            VStack(spacing: 0) {
                Text(current.map(fmtPace) ?? "--:--").font(.system(size: 44 * k, weight: .heavy).monospacedDigit()).foregroundStyle(creme)
                Text("min/km").font(.system(size: 10 * k, weight: .semibold)).foregroundStyle(sauge)
            }
            Text(status).font(.system(size: 14 * k, weight: .bold)).foregroundStyle(ok ? citron : (delta.map { $0 < 0 } ?? false ? alerte : creme))
            gap
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(surface).frame(height: 6)
                    Capsule().fill(citron).frame(width: w * CGFloat((high - low) / 180), height: 6)
                        .offset(x: w * CGFloat(((low - (target - 90)) / 180)))
                    if current != nil {
                        Circle().fill(creme).frame(width: 14, height: 14).offset(x: w * CGFloat(pos) - 7, y: -4)
                            .animation(.easeInOut(duration: 0.8), value: pos)
                    }
                }
            }
            .frame(height: 14).padding(.horizontal, 14)
            gap
            HStack(spacing: 8) {
                Text("vite ←").font(.system(size: 10 * k, weight: .semibold)).foregroundStyle(sauge)
                if let hr = heartRate { Text("\(Int(hr)) bpm").font(.system(size: 13 * k, weight: .bold).monospacedDigit()).foregroundStyle(creme) }
                Text("→ lent").font(.system(size: 10 * k, weight: .semibold)).foregroundStyle(sauge)
            }
        }
    }

    // MARK: Message de Jeffrey

    private var message: some View {
        ZStack {
            citron.ignoresSafeArea()
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    JeffreyVoiceView(speaking: true, size: 18, color: Color.black.opacity(0.75))
                    Text("JEFFREY").font(.system(size: 12, weight: .heavy)).foregroundStyle(Color.black.opacity(0.6)).tracking(1.2)
                }
                Text(scene.subtitle ?? "").font(.system(size: 19 * k, weight: .heavy)).foregroundStyle(Color.black)
                    .multilineTextAlignment(.center).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, dotsInset)
        }
    }

    // MARK: Montée

    private var climb: some View {
        VStack(spacing: 0) {
            header(scene.title, color: citron)
            gap
            ZStack(alignment: .bottomLeading) {
                ClimbShape(grade: scene.value ?? 5).stroke(surface, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                ClimbShape(grade: scene.value ?? 5).trim(from: 0, to: 0.55).stroke(citron, style: StrokeStyle(lineWidth: 8, lineCap: .round))
            }
            .frame(height: 48 * k).padding(.horizontal, 18)
            gap
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: "%.0f", scene.progress ?? 0) + " m").font(.system(size: 30 * k, weight: .heavy).monospacedDigit()).foregroundStyle(creme)
                if let hr = heartRate { Text("\(Int(hr)) bpm").font(.system(size: 14 * k, weight: .bold).monospacedDigit()).foregroundStyle(sauge) }
            }
            gap
            VStack(spacing: 3) {
                Text(scene.subtitle ?? "D+").font(.system(size: 12 * k, weight: .semibold)).foregroundStyle(sauge)
                if let c = scene.caption { Text(c).font(.system(size: 12 * k, weight: .medium)).foregroundStyle(creme).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.85) }
            }
        }
    }

    // MARK: Fantôme

    private var ghost: some View {
        let d = scene.value ?? 0
        let ahead = d >= 0
        return VStack(spacing: 0) {
            header(scene.title, color: citron)
            gap
            VStack(spacing: 0) {
                Text("\(ahead ? "+" : "−")\(Int(abs(d).rounded())) s").font(.system(size: 44 * k, weight: .heavy).monospacedDigit()).foregroundStyle(ahead ? citron : alerte)
                Text(ahead ? "d'avance" : "de retard").font(.system(size: 14 * k, weight: .bold)).foregroundStyle(creme)
            }
            gap
            GeometryReader { geo in
                let w = geo.size.width
                let p = CGFloat(min(1, max(0, scene.progress ?? 0)))
                ZStack(alignment: .leading) {
                    Capsule().fill(surface).frame(height: 8)
                    Capsule().fill(citron).frame(width: w * p, height: 8)
                    Rectangle().fill(sauge).frame(width: 3, height: 14).offset(x: w * p - 3, y: -3)
                }
            }
            .frame(height: 14).padding(.horizontal, 14)
            gap
            VStack(spacing: 3) {
                Text(scene.subtitle ?? "").font(.system(size: 12 * k, weight: .semibold)).foregroundStyle(sauge)
                if let hr = heartRate { Text("\(Int(hr)) bpm").font(.system(size: 13 * k, weight: .bold).monospacedDigit()).foregroundStyle(creme) }
            }
        }
    }

    // MARK: Fête

    private var celebration: some View {
        ZStack {
            RadialGradient(colors: [citron.opacity(0.45), Color.black], center: .init(x: 0.5, y: 0.35), startRadius: 10, endRadius: 150).ignoresSafeArea()
            VStack(spacing: 8) {
                Text(scene.title.uppercased()).font(.system(size: 12, weight: .heavy)).foregroundStyle(citron).tracking(1.5)
                JIcon("arrivee", size: 34 * k).foregroundStyle(citron)
                Text(scene.subtitle ?? "").font(.system(size: 20 * k, weight: .heavy)).foregroundStyle(creme).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                Text(Formatters.elapsed(elapsed)).font(.system(size: 14, weight: .bold).monospacedDigit()).foregroundStyle(sauge)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, dotsInset)
        }
    }

    // MARK: Helpers

    /// Titre à gauche, à hauteur de l'heure système ; place réservée à droite pour l'heure.
    private func header(_ text: String, color: Color) -> some View {
        Text(text.uppercased()).font(.system(size: 13 * k, weight: .heavy)).foregroundStyle(color).tracking(1.2).lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .padding(.trailing, 62)
            .frame(height: 24)
    }

    private func fmtPace(_ secPerKm: Double) -> String {
        let s = Int(secPerKm.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Profil stylisé d'une côte : plus la pente est forte, plus la courbe monte.
private struct ClimbShape: Shape {
    var grade: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let rise = min(rect.height, rect.height * CGFloat(min(1, max(0.25, grade / 12))))
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - rise),
                   control1: CGPoint(x: rect.minX + rect.width * 0.45, y: rect.maxY),
                   control2: CGPoint(x: rect.minX + rect.width * 0.6, y: rect.maxY - rise))
        return p
    }
}

/// Haptiques de scène : changement d'épisode, 3-2-1 du compte à rebours, sortie de zone, fête.
@MainActor
final class SceneHaptics {
    static let shared = SceneHaptics()
    private var lastSceneId: String?
    private var lastTick: Int = -1
    private var lastZoneExitAt: Date = .distantPast
    private var wasInside = true

    func observe(_ scene: WatchScene?, heartRate: Double?, now: Date = Date()) {
        guard let scene else { lastSceneId = nil; lastTick = -1; return }
        if scene.id != lastSceneId {
            lastSceneId = scene.id
            lastTick = -1
            wasInside = true
            switch scene.kind {
            case .celebration: WKInterfaceDevice.current().play(.success)
            case .message: WKInterfaceDevice.current().play(.notification)
            default: WKInterfaceDevice.current().play(.directionUp)
            }
        }
        if scene.kind == .countdown || scene.kind == .interval, let end = scene.endsAt {
            let remaining = Int(max(0, end.timeIntervalSince(now)).rounded())
            if remaining <= 3, remaining != lastTick {
                lastTick = remaining
                WKInterfaceDevice.current().play(remaining == 0 ? .notification : .click)
            }
        }
        if scene.kind == .zone, let hr = heartRate, let low = scene.low, let high = scene.high {
            let inside = hr >= low && hr <= high
            if wasInside, !inside, now.timeIntervalSince(lastZoneExitAt) > 20 {
                lastZoneExitAt = now
                WKInterfaceDevice.current().play(hr > high ? .directionDown : .directionUp)
            }
            wasInside = inside
        }
    }
}

/// Page « stats » de la montre (à droite du direct) : zones cardiaques quand il y en a, puis les chiffres utiles au sport.
struct WatchStatsView: View {
    let mirror: CoachMirror
    let snapshot: MetricsSnapshot
    let elapsed: TimeInterval

    private let citron = JeffreyPalette.citron
    private let creme = JeffreyPalette.creme
    private let sauge = JeffreyPalette.sauge
    private let surface = JeffreyPalette.surface
    private let alerte = JeffreyPalette.alerte

    private var zoneColors: [Color] { [sauge.opacity(0.7), citron.opacity(0.55), citron, Color.orange, alerte] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // En-tête sur la ligne de l'heure système.
                HStack(spacing: 8) {
                    Text("STATS").font(.system(size: 12, weight: .heavy)).foregroundStyle(sauge).tracking(1.2)
                    Text(Formatters.elapsed(elapsed)).font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(creme)
                }
                .frame(height: 24).padding(.trailing, 62).padding(.top, 10)
                if let z = mirror.zoneSeconds, z.reduce(0, +) > 0 { zones(z) }
                statGrid
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .ignoresSafeArea(edges: .top)
    }

    private func zones(_ z: [Int]) -> some View {
        let total = max(1, z.reduce(0, +))
        return VStack(alignment: .leading, spacing: 4) {
            Text("Zones cardiaques").font(.system(size: 10, weight: .bold)).foregroundStyle(creme)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        let w = geo.size.width * CGFloat(z[i]) / CGFloat(total)
                        if z[i] > 0 {
                            RoundedRectangle(cornerRadius: 2).fill(zoneColors[i]).frame(width: max(3, w - 2))
                        }
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { i in
                    VStack(spacing: 1) {
                        Text("Z\(i + 1)").font(.system(size: 8, weight: .heavy)).foregroundStyle(z[i] > 0 ? zoneColors[i] : sauge.opacity(0.4))
                        Text(z[i] > 0 ? (z[i] < 60 ? "\(z[i]) s" : Formatters.humanDuration(TimeInterval(z[i]))) : "–").font(.system(size: 8, weight: .semibold).monospacedDigit()).foregroundStyle(sauge)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(surface))
    }

    private var statGrid: some View {
        let hr = snapshot.heartRate ?? mirror.heartRate
        let kind = mirror.kind
        let energy = snapshot.activeEnergy ?? mirror.energy
        let distance = snapshot.distance ?? mirror.distance
        let avgSpeed: Double? = {
            if let d = distance, d > 20, elapsed > 30 { return d / elapsed }
            return mirror.averageSpeed
        }()
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                stat("frequence-cardiaque", hr.map { "\(Int($0))" } ?? "--", "bpm")
                stat("frequence-cardiaque", mirror.averageHeartRate.map { "\(Int($0))" } ?? "--", "moy.")
            }
            HStack(spacing: 6) {
                stat("energie", energy.map { "\(Int($0))" } ?? "--", "kcal")
                if kind == .cycling {
                    stat("allure", avgSpeed.map { String(format: "%.1f", $0 * 3.6) } ?? "--", "km/h moy.")
                } else if kind.usesDistance {
                    stat("allure", avgSpeed.flatMap { pace($0) } ?? "--", "/km moy.")
                } else {
                    stat("chronometre", Formatters.elapsed(elapsed), "temps")
                }
            }
            if kind.usesDistance {
                HStack(spacing: 6) {
                    stat("distance", distance.map { String(format: "%.2f", $0 / 1000) } ?? "--", "km")
                    stat("allure", mirror.paceSecPerKm.flatMap { kind == .cycling ? String(format: "%.1f", 3600 / $0) : pace(1000 / $0) } ?? "--", kind == .cycling ? "km/h" : "/km")
                }
            }
        }
    }

    private func pace(_ metersPerSecond: Double) -> String? {
        guard metersPerSecond > 0.3 else { return nil }
        let s = Int((1000 / metersPerSecond).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func stat(_ icon: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            JIcon(icon, size: 11).foregroundStyle(sauge)
            Text(value).font(.system(size: 19, weight: .heavy).monospacedDigit()).foregroundStyle(creme).lineLimit(1).minimumScaleFactor(0.7)
            Text(unit).font(.system(size: 9, weight: .bold)).foregroundStyle(sauge)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(surface))
    }
}
