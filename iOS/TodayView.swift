import SwiftUI
import HealthKit

struct TodayView: View {
    @EnvironmentObject private var coach: CoachSession
    @ObservedObject var history: WorkoutHistory
    var goToSessions: () -> Void
    @AppStorage(Prefs.kind) private var kindRaw: String = WorkoutKind.running.rawValue
    @AppStorage(Prefs.userName) private var userName: String = ""
    @State private var showObjective = false

    private var kind: WorkoutKind { WorkoutKind(rawValue: kindRaw) ?? .running }
    private var weekWorkouts: [HKWorkout] {
        guard let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        return history.workouts.filter { $0.startDate >= start }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    JeffreyHeader(trailing: AnyView(watchBadge))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Salut\(userName.isEmpty ? "" : ", \(userName)").").font(.display(22, weight: .bold)).foregroundStyle(Theme.muted)
                        Text("On bouge ?").font(.display(32, weight: .black)).foregroundStyle(.white)
                    }
                    JeffreyBubble(text: todayBubble)
                    weekCard
                    if let last = history.workouts.first { lastOutingRow(last) }
                    if let ref = ReferenceRoute.load() { referenceRow(ref) }
                    KindChips(kindRaw: $kindRaw)
                    PrimaryButton(title: "Démarrer avec Jeffrey") { showObjective = true }
                    if let err = coach.errorMessage {
                        Text(err).font(.caption).foregroundStyle(Theme.pulse)
                    }
                }
                .padding(18)
                .padding(.bottom, 70)
            }
        }
        .sheet(isPresented: $showObjective) {
            ObjectiveView(kind: kind) { goal in
                showObjective = false
                coach.start(kind: kind, mode: CaptureMode(rawValue: UserDefaults.standard.string(forKey: Prefs.mode) ?? "") ?? .companion, goal: goal)
            }
        }
    }

    private var todayBubble: String {
        guard let last = SessionSummary.loadAll().first else { return "On commence tranquille ? Dis-moi ce que tu veux faire." }
        if let advice = last.advice, !advice.isEmpty { return "Mon conseil après ta dernière sortie : \(advice)" }
        return "Quel est ton objectif aujourd'hui ?"
    }

    private var watchBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(coach.connectivity.isReachable ? Theme.lime : Theme.muted).frame(width: 7, height: 7)
            JIcon("montre", size: 14)
        }
        .foregroundStyle(coach.connectivity.isReachable ? .white : Theme.muted)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Capsule().fill(Theme.surfaceRaised))
    }

    private var weekCard: some View {
        let w = weekWorkouts
        let time = w.reduce(0.0) { $0 + $1.duration }
        let dist = w.compactMap(WorkoutHistory.distanceMeters).reduce(0, +)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Cette semaine").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            HStack(spacing: 0) {
                stat("course", "\(w.count)", "séances")
                stat("distance", dist > 0 ? String(format: "%.2f", dist / 1000).replacingOccurrences(of: ".", with: ",") : "0", "km")
                stat("chronometre", Formatters.humanDuration(time), "temps")
            }
        }
        .card()
    }

    private func stat(_ icon: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 4) {
            JIcon(icon, size: 16).foregroundStyle(Theme.muted)
            Text(value).font(.display(22, weight: .black).monospacedDigit()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            Text(unit).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func lastOutingRow(_ w: HKWorkout) -> some View {
        Button(action: goToSessions) {
            HStack(spacing: 12) {
                JIcon("course", size: 18).foregroundStyle(Theme.creme)
                    .frame(width: 38, height: 38).background(Circle().fill(Theme.surfaceRaised))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dernière sortie").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
                    Text("\(WorkoutKind(activityType: w.workoutActivityType).label)\(WorkoutHistory.distanceMeters(w).map { " · \(Formatters.distance($0))" } ?? "")")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    Text("\(relative(w.startDate)) · \(Formatters.elapsed(w.duration))").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                }
                Spacer()
                JIcon("suivant", size: 14).foregroundStyle(Theme.muted)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private func referenceRow(_ ref: ReferenceRoute) -> some View {
        HStack(spacing: 12) {
            JIcon("refaire-parcours", size: 18).foregroundStyle(Theme.citron)
                .frame(width: 38, height: 38).background(Circle().fill(Theme.surfaceRaised))
            VStack(alignment: .leading, spacing: 2) {
                Text("Parcours à refaire").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
                Text(ref.name).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Text("\(Formatters.distance(ref.totalDistance)) · D+ \(Int(ref.totalGain)) m").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button { ReferenceRoute.clear() } label: { JIcon("fermer", size: 16).foregroundStyle(Theme.muted) }
        }
        .card()
    }

    private func relative(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Aujourd'hui" }
        if cal.isDateInYesterday(date) { return "Hier" }
        return date.formatted(.dateTime.weekday(.wide).day().month()).capitalized
    }
}
