import SwiftUI
import HealthKit

/// Accueil hors séance : semaine en cours, dernière séance, coach, montre.
struct HomeView: View {
    @EnvironmentObject private var coach: CoachSession
    @ObservedObject var history: WorkoutHistory
    var onOpenHistory: () -> Void
    var onOpenSettings: () -> Void

    @AppStorage(Prefs.level) private var level: String = AthleteLevel.amateur.rawValue
    @AppStorage(Prefs.goal) private var goal: String = ""

    private var weekWorkouts: [HKWorkout] {
        let cal = Calendar.current
        guard let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        return history.workouts.filter { $0.startDate >= start }
    }

    var body: some View {
        VStack(spacing: 14) {
            greeting
            weekCard
            if let last = history.workouts.first { lastSessionCard(last) }
            coachCard
        }
    }

    // MARK: Salutation

    private var greeting: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let word = hour < 5 ? "Bonne nuit" : (hour < 12 ? "Bonjour" : (hour < 18 ? "Bon après-midi" : "Bonsoir"))
        return VStack(alignment: .leading, spacing: 4) {
            Text(word.uppercased()).font(.display(12, weight: .black)).tracking(3).foregroundStyle(Theme.muted)
            Text(headline).font(.display(24, weight: .black)).foregroundStyle(.white)
            Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var headline: String {
        let n = weekWorkouts.count
        switch n {
        case 0: return "On lance la semaine ?"
        case 1: return "Une séance faite, on enchaîne."
        case 2...3: return "Belle régularité cette semaine."
        default: return "Grosse semaine, bravo."
        }
    }

    // MARK: Semaine

    private var weekCard: some View {
        let w = weekWorkouts
        let time = w.reduce(0.0) { $0 + $1.duration }
        let dist = w.compactMap(WorkoutHistory.distanceMeters).reduce(0, +)
        let kcal = w.compactMap(WorkoutHistory.energyKcal).reduce(0, +)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CETTE SEMAINE").font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
                Spacer()
                weekDots
            }
            HStack(spacing: 0) {
                weekStat("\(w.count)", w.count == 1 ? "séance" : "séances", Theme.lime)
                weekStat(Formatters.elapsed(time), "temps", .white)
                weekStat(dist > 0 ? Formatters.distance(dist) : "--", "distance", Theme.ice)
                weekStat(kcal > 0 ? "\(Int(kcal))" : "--", "kcal", Theme.ember)
            }
        }
        .card()
    }

    /// Sept points, un par jour de la semaine, allumés les jours avec séance.
    private var weekDots: some View {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let today = cal.startOfDay(for: Date())
        return HStack(spacing: 5) {
            ForEach(days, id: \.self) { day in
                let active = weekWorkouts.contains { cal.isDate($0.startDate, inSameDayAs: day) }
                let future = day > today
                Circle()
                    .fill(active ? Theme.lime : Color.white.opacity(future ? 0.08 : 0.2))
                    .frame(width: 7, height: 7)
                    .shadow(color: active ? Theme.lime.opacity(0.8) : .clear, radius: 4)
            }
        }
    }

    private func weekStat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display(20, weight: .black).monospacedDigit()).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Dernière séance

    private func lastSessionCard(_ w: HKWorkout) -> some View {
        Button(action: onOpenHistory) {
            HStack(spacing: 12) {
                Image(systemName: "figure.run")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.background)
                    .frame(width: 42, height: 42).background(Circle().fill(Theme.lime))
                VStack(alignment: .leading, spacing: 3) {
                    Text("DERNIÈRE SÉANCE").font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
                    Text("\(WorkoutKind(activityType: w.workoutActivityType).label) · \(relative(w.startDate))")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    HStack(spacing: 10) {
                        Text(Formatters.elapsed(w.duration))
                        if let d = WorkoutHistory.distanceMeters(w) {
                            Text(Formatters.distance(d))
                            if let p = Formatters.pace(speedMetersPerSecond: d / max(1, w.duration)) { Text(p) }
                        }
                    }
                    .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ice)
                }
                Spacer()
                Image(systemName: "map").foregroundStyle(Theme.muted)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private func relative(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "aujourd'hui" }
        if cal.isDateInYesterday(date) { return "hier" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        return days < 7 ? "il y a \(days) j" : date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Coach

    private var coachCard: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.lime)
                    .frame(width: 42, height: 42).background(Circle().fill(Theme.surfaceRaised))
                VStack(alignment: .leading, spacing: 3) {
                    Text("TON COACH").font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
                    Text("Profil \((AthleteLevel(rawValue: level) ?? .amateur).label.lowercased())")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    Text(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Aucun objectif défini, il te le demandera." : "Objectif : \(goal)")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
            }
            .card()
        }
        .buttonStyle(.plain)
    }
}
