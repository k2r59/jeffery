import SwiftUI
import HealthKit
import UIKit

struct TodayView: View {
    @EnvironmentObject private var coach: CoachSession
    @ObservedObject var history: WorkoutHistory
    var goToSessions: () -> Void
    var goToJeffrey: () -> Void
    @AppStorage(Prefs.kind) private var kindRaw: String = WorkoutKind.running.rawValue
    @AppStorage(Prefs.userName) private var userName: String = ""
    @State private var showObjective = false
    @State private var reference: ReferenceRoute?
    @State private var lastAdvice: String?

    /// Les cinq activités de l'écran d'accueil, avec leur pictogramme et l'intitulé du bouton.
    private struct KindOption: Identifiable {
        let id: String
        let kind: WorkoutKind
        let icon: String
        let label: String
        let cta: String
    }

    private static let options: [KindOption] = [
        KindOption(id: "course", kind: .running, icon: "course", label: "Course", cta: "Démarrer ma course"),
        KindOption(id: "marche", kind: .walking, icon: "marche", label: "Marche", cta: "Démarrer ma marche"),
        KindOption(id: "velo", kind: .cycling, icon: "velo", label: "Vélo", cta: "Démarrer mon vélo"),
        KindOption(id: "rando", kind: .hiking, icon: "randonnee", label: "Rando", cta: "Démarrer ma rando"),
        KindOption(id: "renfo", kind: .functionalStrength, icon: "renforcement", label: "Renfo", cta: "Démarrer mon renfo"),
    ]

    /// Valeurs relevées au pixel sur la maquette (iPhone 390 x 844 pt).
    private enum Metrics {
        static let margin: CGFloat = 13        // marge écran des cartes
        static let textInset: CGFloat = 6      // la salutation est rentrée de 6 pt de plus que les cartes
        static let cardPadding: CGFloat = 13   // padding horizontal interne des cartes
        static let cardRadius: CGFloat = 16
    }

    private var kind: WorkoutKind { WorkoutKind(rawValue: kindRaw) ?? .running }
    private var selected: KindOption { Self.options.first { $0.kind == kind } ?? Self.options[0] }

    private var weekInterval: DateInterval? { Calendar.current.dateInterval(of: .weekOfYear, for: Date()) }
    private var weekWorkouts: [HKWorkout] {
        guard let start = weekInterval?.start else { return [] }
        return history.workouts.filter { $0.startDate >= start }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    greeting
                    heroCard
                    weekCard
                    if let last = history.workouts.first { lastOutingRow(last) }
                    if let reference { referenceRow(reference) }
                    talkRow
                    if let err = coach.errorMessage {
                        Text(err).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.alerte)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, Metrics.margin)
                .padding(.top, 10)
                .padding(.bottom, 80)
            }
        }
        .task {
            reference = ReferenceRoute.load()
            lastAdvice = SessionSummary.loadAll().first?.advice
        }
        .sheet(isPresented: $showObjective) {
            ObjectiveView(kind: kind) { goal in
                showObjective = false
                coach.start(kind: kind, mode: CaptureMode(rawValue: UserDefaults.standard.string(forKey: Prefs.mode) ?? "") ?? .companion, goal: goal)
            }
        }
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(spacing: 9) {
            JeffreyWordmark(size: 23, signature: true)
            Spacer(minLength: 4)
            watchBadge
            ProfileAvatar(name: userName, size: 38)
        }
    }

    private var watchBadge: some View {
        let connected = coach.connectivity.isReachable
        return HStack(spacing: 8) {
            JIcon("montre", size: 17).foregroundStyle(connected ? Theme.creme : Theme.muted)
            Circle().fill(connected ? Theme.citron : Theme.muted).frame(width: 7, height: 7)
            Text(connected ? "Connectée" : "Hors ligne")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(connected ? Theme.creme : Theme.muted)
        }
        .padding(.horizontal, 13)
        .frame(height: 33)
        .background(Capsule().fill(Theme.surfaceRaised))
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: -4) {
            Text(userName.isEmpty ? "Salut" : "Salut, \(userName)")
                .font(.display(20, weight: .bold)).foregroundStyle(Theme.muted)
            Text("On bouge ?")
                .font(.display(36, weight: .black)).foregroundStyle(.white)
        }
        .padding(.horizontal, Metrics.textInset)
        .padding(.bottom, 4)
    }

    // MARK: - Bandeau principal

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("TON MOMENT À TOI")
                    .font(.system(size: 11, weight: .heavy)).tracking(2.0).foregroundStyle(Theme.muted)
                Text("Un pas dehors.\nDu bien dedans.")
                    .font(.display(28, weight: .black)).foregroundStyle(.white)
                Text("Le rythme, c'est toi qui le donnes.")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
            .padding(.bottom, 16)

            kindRow
                .padding(.bottom, 13)
            startButton
                .padding(.bottom, 12)

            Text("Avec Jeffrey, à ton rythme.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 15)
        .background(
            HeroScene()
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Theme.creme.opacity(0.06)))
        )
    }

    private var kindRow: some View {
        HStack(spacing: 6) {
            ForEach(Self.options) { option in
                let isOn = option.kind == kind
                Button {
                    withAnimation(.snappy(duration: 0.2)) { kindRaw = option.kind.rawValue }
                } label: {
                    VStack(spacing: 9) {
                        JIcon(option.icon, size: 23)
                        Text(option.label).font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(isOn ? Theme.background : Theme.creme)
                    .frame(maxWidth: .infinity)
                    .frame(height: 70)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(isOn ? Theme.citron : Theme.surfaceRaised.opacity(0.8))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var startButton: some View {
        Button { showObjective = true } label: {
            ZStack {
                Text(selected.cta).font(.display(15, weight: .black))
                HStack {
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 15, weight: .bold))
                }
            }
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 45)
            .background(Capsule().fill(Theme.citron))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Ta semaine

    private var weekCard: some View {
        let w = weekWorkouts
        let time = w.reduce(0.0) { $0 + $1.duration }
        let meters = w.compactMap(WorkoutHistory.distanceMeters).reduce(0, +)
        return VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Ta semaine").font(.display(16, weight: .black)).foregroundStyle(.white)
                Text(weekRange).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
            }
            .padding(.leading, 3)
            HStack(spacing: 0) {
                stat("marche", "\(w.count)", "séances")
                statDivider
                stat("distance", kilometers(meters), "parcourus")
                statDivider
                stat("chronometre", Formatters.humanDuration(time), "en mouvement")
            }
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 12)
        .background(cardShape)
    }

    private var statDivider: some View {
        Rectangle().fill(Theme.creme.opacity(0.10)).frame(width: 1, height: 50)
    }

    private func stat(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            JIcon(icon, size: 17).foregroundStyle(Theme.muted)
            Text(value)
                .font(.display(24, weight: .black))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.55)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    /// « 7,72 km », séparateur décimal français.
    private func kilometers(_ meters: Double) -> String {
        guard meters > 0 else { return "0 km" }
        return (meters / 1000).formatted(.number.precision(.fractionLength(2))) + " km"
    }

    /// « 14 — 20 sept. », ou « 29 sept. — 5 oct. » à cheval sur deux mois.
    private var weekRange: String {
        guard let interval = weekInterval else { return "" }
        let last = interval.end.addingTimeInterval(-1)
        let firstMonth = interval.start.formatted(.dateTime.month(.abbreviated))
        let lastMonth = last.formatted(.dateTime.month(.abbreviated))
        let firstDay = interval.start.formatted(.dateTime.day())
        let lastDay = last.formatted(.dateTime.day())
        return firstMonth == lastMonth
            ? "\(firstDay) — \(lastDay) \(lastMonth)"
            : "\(firstDay) \(firstMonth) — \(lastDay) \(lastMonth)"
    }

    // MARK: - Lignes du bas

    private func lastOutingRow(_ workout: HKWorkout) -> some View {
        rowCard(overline: "DERNIÈRE SORTIE",
                title: WorkoutKind(activityType: workout.workoutActivityType).label,
                subtitle: longDate(workout.startDate),
                action: goToSessions) {
            JIcon("course", size: 20).foregroundStyle(Theme.creme)
        }
    }

    private var talkRow: some View {
        rowCard(overline: nil,
                title: "On en parle ?",
                subtitle: lastAdvice.flatMap { $0.isEmpty ? nil : $0 } ?? "Jeffrey est là pour toi.",
                action: goToJeffrey) {
            Image("jeffrey-ondes-citron").resizable().scaledToFit().frame(width: 22, height: 22)
        }
    }

    private func referenceRow(_ ref: ReferenceRoute) -> some View {
        rowCard(overline: "PARCOURS À REFAIRE",
                title: ref.name,
                subtitle: "\(Formatters.distance(ref.totalDistance)) · D+ \(Int(ref.totalGain)) m",
                action: goToSessions) {
            JIcon("refaire-parcours", size: 20).foregroundStyle(Theme.citron)
        }
    }

    private func rowCard<Icon: View>(overline: String?, title: String, subtitle: String,
                                     action: @escaping () -> Void,
                                     @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                icon().frame(width: 40, height: 40).background(Circle().fill(Theme.surfaceRaised))
                VStack(alignment: .leading, spacing: 2) {
                    if let overline {
                        Text(overline).font(.system(size: 11, weight: .heavy)).tracking(1.6).foregroundStyle(Theme.muted)
                    }
                    Text(title).font(.display(16, weight: .black)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                JIcon("suivant", size: 15).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 13)
            .background(cardShape)
        }
        .buttonStyle(.plain)
    }

    private var cardShape: some View {
        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Theme.creme.opacity(0.06)))
    }

    /// « Mardi 15 septembre », ou Aujourd'hui / Hier.
    private func longDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Aujourd'hui" }
        if calendar.isDateInYesterday(date) { return "Hier" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide)).localizedCapitalized
    }
}

// MARK: - Illustration du bandeau

/// Paysage du bandeau, relevé sur la maquette : ciel dégradé, trois crêtes, sentier en S, sapins et lune.
/// Toutes les valeurs sont des fractions de la carte (364 x 297 pt sur la maquette).
private struct HeroScene: View {
    /// Sapin : x du tronc, hauteur de la base, hauteur de l'arbre, en fractions de la carte.
    private struct PineSpot: Identifiable {
        let id: Int
        let x: CGFloat
        let base: CGFloat
        let height: CGFloat
    }

    private static let pines: [PineSpot] = [
        PineSpot(id: 0, x: 0.714, base: 0.212, height: 0.084),
        PineSpot(id: 1, x: 0.746, base: 0.206, height: 0.084),
        PineSpot(id: 2, x: 0.928, base: 0.215, height: 0.115),
        PineSpot(id: 3, x: 0.958, base: 0.210, height: 0.098),
    ]

    /// Axe du sentier relevé ligne par ligne : position, hauteur, demi-largeur.
    private static let trail: [(x: CGFloat, y: CGFloat, halfWidth: CGFloat)] = [
        (0.862, 0.185, 0.007), (0.752, 0.229, 0.015), (0.738, 0.259, 0.019),
        (0.851, 0.291, 0.026), (0.925, 0.323, 0.032), (0.995, 0.385, 0.045),
    ]

    /// Nom de l'illustration officielle dans le catalogue. Tant qu'elle n'y est pas, la scène est dessinée.
    static let assetName = "paysage-bandeau"

    var body: some View {
        if UIImage(named: Self.assetName) != nil {
            ZStack {
                LinearGradient(colors: [Palette.ground, Palette.skyLeft], startPoint: .leading, endPoint: .trailing)
                Image(Self.assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .allowsHitTesting(false)
        } else {
            drawnScene
        }
    }

    private var drawnScene: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(stops: [.init(color: Palette.ground, location: 0.00),
                                       .init(color: Palette.skyLeft, location: 0.45),
                                       .init(color: Palette.skyRight, location: 1.00)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, Palette.ground], startPoint: .top, endPoint: .bottom)

                crest(w: w, h: h, left: 0.400, peak: 0.175, peakX: 0.70, right: 0.245).fill(Palette.far)
                crest(w: w, h: h, left: 0.560, peak: 0.355, peakX: 0.45, right: 0.490).fill(Palette.mid)

                trailShape(w: w, h: h)
                    .fill(LinearGradient(colors: [Palette.trailNear, Palette.trailFar],
                                         startPoint: .bottom, endPoint: .top))

                Circle()
                    .fill(Palette.moon)
                    .frame(width: w * 0.038, height: w * 0.038)
                    .position(x: w * 0.897, y: h * 0.098)

                ForEach(Self.pines) { pine in
                    Pine()
                        .fill(Palette.pine)
                        .frame(width: h * pine.height * 0.55, height: h * pine.height)
                        .position(x: w * pine.x, y: h * (pine.base - pine.height / 2))
                }

                crest(w: w, h: h, left: 0.880, peak: 0.780, peakX: 0.50, right: 0.920).fill(Palette.ground)
            }
        }
        .allowsHitTesting(false)
    }

    private enum Palette {
        static let skyLeft = Color(red: 0.086, green: 0.126, blue: 0.090)   // #162016
        static let skyRight = Color(red: 0.204, green: 0.275, blue: 0.149)  // #344626
        static let far = Color(red: 0.133, green: 0.176, blue: 0.125)       // #222D20
        static let mid = Color(red: 0.094, green: 0.133, blue: 0.102)       // #18221A
        static let ground = Color(red: 0.078, green: 0.110, blue: 0.082)    // #141C15
        static let pine = Color(red: 0.063, green: 0.090, blue: 0.067)      // #101711
        static let trailNear = Color(red: 0.353, green: 0.416, blue: 0.220)
        static let trailFar = Color(red: 0.600, green: 0.686, blue: 0.396)
        static let moon = Color(red: 0.541, green: 0.612, blue: 0.333)      // #8A9C55
    }

    /// Crête douce : hauteur au bord gauche, au sommet, et au bord droit.
    private func crest(w: CGFloat, h: CGFloat, left: CGFloat, peak: CGFloat,
                       peakX: CGFloat, right: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: 0, y: h * left))
        path.addCurve(to: CGPoint(x: w * peakX, y: h * peak),
                      control1: CGPoint(x: w * peakX * 0.35, y: h * (left - (left - peak) * 0.35)),
                      control2: CGPoint(x: w * peakX * 0.72, y: h * peak))
        path.addCurve(to: CGPoint(x: w, y: h * right),
                      control1: CGPoint(x: w * (peakX + (1 - peakX) * 0.30), y: h * (peak - 0.012)),
                      control2: CGPoint(x: w * (peakX + (1 - peakX) * 0.70), y: h * right))
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()
        return path
    }

    /// Ruban du sentier : bord droit descendu, bord gauche remonté.
    private func trailShape(w: CGFloat, h: CGFloat) -> Path {
        let pts = Self.trail
        var path = Path()
        path.move(to: CGPoint(x: w * (pts[0].x + pts[0].halfWidth), y: h * pts[0].y))
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            path.addCurve(to: CGPoint(x: w * (b.x + b.halfWidth), y: h * b.y),
                          control1: CGPoint(x: w * (a.x + a.halfWidth), y: h * (a.y + (b.y - a.y) * 0.55)),
                          control2: CGPoint(x: w * (b.x + b.halfWidth), y: h * (b.y - (b.y - a.y) * 0.55)))
        }
        for i in stride(from: pts.count - 1, through: 1, by: -1) {
            let a = pts[i], b = pts[i - 1]
            path.addCurve(to: CGPoint(x: w * (b.x - b.halfWidth), y: h * b.y),
                          control1: CGPoint(x: w * (a.x - a.halfWidth), y: h * (a.y - (a.y - b.y) * 0.55)),
                          control2: CGPoint(x: w * (b.x - b.halfWidth), y: h * (b.y + (a.y - b.y) * 0.55)))
        }
        path.closeSubpath()
        return path
    }
}

/// Sapin stylisé à trois étages.
private struct Pine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tiers: [(top: CGFloat, bottom: CGFloat, half: CGFloat)] =
            [(0.00, 0.46, 0.30), (0.28, 0.74, 0.40), (0.54, 1.00, 0.50)]
        for tier in tiers {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * tier.top))
            path.addLine(to: CGPoint(x: rect.midX + rect.width * tier.half, y: rect.minY + rect.height * tier.bottom))
            path.addLine(to: CGPoint(x: rect.midX - rect.width * tier.half, y: rect.minY + rect.height * tier.bottom))
            path.closeSubpath()
        }
        return path
    }
}
