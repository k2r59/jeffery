import SwiftUI
import HealthKit
import MapKit
import CoreLocation

struct SessionsView: View {
    @ObservedObject var history: WorkoutHistory
    @State private var coached = SessionSummary.loadAll()
    @State private var hidden = HiddenWorkouts.ids
    /// Suppression en attente de confirmation. Un seul dialogue : deux `confirmationDialog` sur la même vue
    /// ne s'affichent pas de façon fiable (le second reste muet).
    private enum Deletion: Equatable {
        case workout(HKWorkout)
        case coached(SessionSummary)
        static func == (a: Deletion, b: Deletion) -> Bool {
            switch (a, b) {
            case let (.workout(x), .workout(y)): return x.uuid == y.uuid
            case let (.coached(x), .coached(y)): return x.id == y.id
            default: return false
            }
        }
    }
    @State private var pending: Deletion?
    /// Mode sélection : cases à cocher sur chaque ligne, « Tout sélectionner » et suppression groupée.
    @State private var selecting = false
    @State private var selectedWorkouts: Set<UUID> = []
    @State private var selectedCoached: Set<String> = []
    @State private var confirmBulk = false

    private var selectedCount: Int { selectedWorkouts.count + selectedCoached.count }
    private var allSelected: Bool {
        selectedWorkouts.count == visibleWorkouts.count && selectedCoached.count == orphanCoached.count && selectedCount > 0
    }

    /// Séances coachées par Jeffrey qui ne sont pas (ou plus) visibles dans Santé : elles restent listées,
    /// pour que l'historique ne disparaisse jamais si l'accès à Santé est coupé.
    private var orphanCoached: [SessionSummary] {
        coached.filter { s in
            !visibleWorkouts.contains { w in
                abs(w.startDate.timeIntervalSince(s.date)) < 600 && w.startDate < s.date.addingTimeInterval(s.elapsed + 600)
            }
        }
    }

    private var weekCount: (Int, Double) {
        guard let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start else { return (0, 0) }
        let w = visibleWorkouts.filter { $0.startDate >= start }
        return (w.count, w.compactMap(WorkoutHistory.distanceMeters).reduce(0, +))
    }

    private var visibleWorkouts: [HKWorkout] { history.workouts.filter { !hidden.contains($0.uuid.uuidString) } }

    private var groups: [(String, [HKWorkout])] {
        let cal = Calendar.current
        var today: [HKWorkout] = [], yesterday: [HKWorkout] = [], week: [HKWorkout] = [], earlier: [HKWorkout] = []
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        for w in visibleWorkouts {
            if cal.isDateInToday(w.startDate) { today.append(w) }
            else if cal.isDateInYesterday(w.startDate) { yesterday.append(w) }
            else if w.startDate >= weekStart { week.append(w) }
            else { earlier.append(w) }
        }
        return [("Aujourd'hui", today), ("Hier", yesterday), ("Cette semaine", week), ("Plus tôt", earlier)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        JeffreyHeader()
                        Text("Tes séances").font(.display(30, weight: .black)).foregroundStyle(.white)
                        HStack {
                            Text(selecting ? "\(selectedCount) sélectionnée\(selectedCount > 1 ? "s" : "")" : "On construit le rythme.")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(selecting ? Theme.lime : Theme.muted)
                            Spacer()
                            if selecting {
                                Button(allSelected ? "Tout désélectionner" : "Tout sélectionner") { toggleAll() }
                                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.creme)
                            } else {
                                Text("\(weekCount.0) séance\(weekCount.0 > 1 ? "s" : "") · \(Formatters.distance(weekCount.1))")
                                    .font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(Theme.muted)
                            }
                        }
                        if !visibleWorkouts.isEmpty || !orphanCoached.isEmpty {
                            HStack(spacing: 10) {
                                Button(selecting ? "Terminer" : "Sélectionner") {
                                    withAnimation(.snappy) { selecting.toggle(); selectedWorkouts = []; selectedCoached = [] }
                                }
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.creme)
                                .padding(.horizontal, 14).frame(height: 34)
                                .background(Capsule().fill(Theme.surfaceRaised))
                                .accessibilityIdentifier("Sélectionner")
                                if selecting, selectedCount > 0 {
                                    Button { confirmBulk = true } label: {
                                        HStack(spacing: 6) { JIcon("fermer", size: 13); Text("Supprimer (\(selectedCount))") }
                                            .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.alerte)
                                            .padding(.horizontal, 14).frame(height: 34)
                                            .background(Capsule().fill(Theme.alerte.opacity(0.14)))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("Supprimer la sélection")
                                }
                                Spacer()
                            }
                        }
                        if visibleWorkouts.isEmpty, orphanCoached.isEmpty {
                            Text(history.isLoading ? "Lecture de Santé…" : "Aucune séance sur les 90 derniers jours.")
                                .font(.subheadline).foregroundStyle(Theme.muted).padding(.top, 20)
                        }
                        if visibleWorkouts.isEmpty, !history.isLoading {
                            healthAccessCard
                        }
                        if !orphanCoached.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Avec Jeffrey").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                                ForEach(orphanCoached) { s in
                                    if selecting {
                                        Button { toggle(coached: s.id) } label: {
                                            selectable(selectedCoached.contains(s.id)) { coachedRow(s) }
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        SwipeToDelete { pending = .coached(s) } content: { coachedRow(s) }
                                    }
                                }
                            }
                        }
                        ForEach(groups, id: \.0) { title, items in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                                ForEach(items, id: \.uuid) { w in
                                    if selecting {
                                        Button { toggle(workout: w.uuid) } label: {
                                            selectable(selectedWorkouts.contains(w.uuid)) { row(w) }
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        SwipeToDelete { pending = .workout(w) } content: {
                                            NavigationLink { RedoRouteView(workout: w, history: history) } label: { row(w) }
                                                .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(18)
                    .padding(.bottom, 70)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await history.load() }
            .confirmationDialog("Supprimer \(selectedCount) séance\(selectedCount > 1 ? "s" : "") ?", isPresented: $confirmBulk, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) { removeSelection() }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Leurs bilans et tracés seront effacés. Les séances venues de l'app Exercice disparaissent de cette liste mais restent dans Santé.")
            }
            .confirmationDialog("Supprimer cette séance ?",
                                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    switch pending {
                    case .workout(let w): remove(w)
                    case .coached(let s): removeCoached(s)
                    case nil: break
                    }
                }
                Button("Annuler", role: .cancel) { pending = nil }
            } message: {
                if case .workout = pending {
                    Text("Elle disparaît de cette liste, avec son bilan et son tracé. La séance reste dans l'app Santé : Jeffrey n'a pas le droit d'y effacer ce qu'il n'a pas écrit.")
                } else {
                    Text("Son bilan et son tracé seront effacés.")
                }
            }
        }
    }

    /// Ligne en mode sélection : une pastille à gauche, cochée ou non.
    private func selectable<Content: View>(_ isOn: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().strokeBorder(isOn ? Theme.lime : Theme.muted, lineWidth: 2).frame(width: 22, height: 22)
                if isOn { Circle().fill(Theme.lime).frame(width: 13, height: 13) }
            }
            content()
        }
    }

    private func toggle(workout id: UUID) {
        if selectedWorkouts.contains(id) { selectedWorkouts.remove(id) } else { selectedWorkouts.insert(id) }
    }

    private func toggle(coached id: String) {
        if selectedCoached.contains(id) { selectedCoached.remove(id) } else { selectedCoached.insert(id) }
    }

    private func toggleAll() {
        if allSelected {
            selectedWorkouts = []; selectedCoached = []
        } else {
            selectedWorkouts = Set(visibleWorkouts.map(\.uuid))
            selectedCoached = Set(orphanCoached.map(\.id))
        }
    }

    /// Supprime tout ce qui est coché, d'un coup.
    private func removeSelection() {
        for w in visibleWorkouts where selectedWorkouts.contains(w.uuid) { remove(w, reload: false) }
        for s in orphanCoached where selectedCoached.contains(s.id) { removeCoached(s, reload: false) }
        hidden = HiddenWorkouts.ids
        coached = SessionSummary.loadAll()
        selectedWorkouts = []; selectedCoached = []
        withAnimation(.snappy) { selecting = false }
    }

    /// Retire une séance de Santé de la liste de Jeffrey : bilan et tracé effacés, la séance reste dans Santé.
    private func remove(_ workout: HKWorkout?, reload: Bool = true) {
        guard let workout else { return }
        defer { if reload { pending = nil } }
        if let s = SessionSummary.matching(start: workout.startDate, end: workout.endDate, in: coached) {
            SessionSummary.delete(id: s.id)
            if let route = LocalRoute.matching(start: workout.startDate, end: workout.endDate) { LocalRoute.delete(id: route.id) }
        }
        HiddenWorkouts.hide(workout.uuid.uuidString)
        if reload {
            hidden = HiddenWorkouts.ids
            coached = SessionSummary.loadAll()
        }
    }

    private func removeCoached(_ summary: SessionSummary?, reload: Bool = true) {
        guard let summary else { return }
        defer { if reload { pending = nil } }
        SessionSummary.delete(id: summary.id)
        if let route = LocalRoute.matching(start: summary.date, end: summary.date.addingTimeInterval(summary.elapsed + 60)) {
            LocalRoute.delete(id: route.id)
        }
        if reload { coached = SessionSummary.loadAll() }
    }

    /// Santé ne renvoie rien : souvent l'autorisation de lecture a été coupée (réinstallation de l'app).
    private var healthAccessCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                JIcon("information", size: 16).foregroundStyle(Theme.alerte)
                Text("Santé ne renvoie aucune séance").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            }
            Text("Vérifie l'accès : Réglages › Santé › Accès aux données › Jeffrey, et active la lecture des entraînements. Tes séances coachées restent listées ci-dessous.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("Ouvrir les réglages").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(Capsule().fill(Theme.lime))
            }
            .buttonStyle(.plain)
        }
        .card()
    }

    /// Séance coachée par Jeffrey, affichée même sans Santé.
    private func coachedRow(_ s: SessionSummary) -> some View {
        HStack(spacing: 12) {
            JIcon("course", size: 17).foregroundStyle(Theme.creme)
                .frame(width: 34, height: 34).background(Circle().fill(Theme.surfaceRaised))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(s.kind.label) · \(s.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Text("\(Formatters.elapsed(s.elapsed))\(s.distance.map { " · \(Formatters.distance($0))" } ?? "")\(s.averageHeartRate.map { " · \(Int($0)) bpm" } ?? "")")
                    .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            Spacer()
            Text("Avec Jeffrey").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.lime)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
    }

    private func row(_ w: HKWorkout) -> some View {
        let coached = SessionSummary.matching(start: w.startDate, end: w.endDate, in: coached) != nil || WorkoutHistory.sourceLabel(w) == "Jeffrey"
        return HStack(spacing: 12) {
            JIcon("course", size: 17).foregroundStyle(Theme.creme)
                .frame(width: 34, height: 34).background(Circle().fill(Theme.surfaceRaised))
            VStack(alignment: .leading, spacing: 2) {
                Text(WorkoutKind(activityType: w.workoutActivityType).label).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Text("\(Formatters.elapsed(w.duration))\(WorkoutHistory.distanceMeters(w).map { " · \(Formatters.distance($0))" } ?? "")")
                    .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(coached ? "Avec Jeffrey" : "Apple Watch").font(.system(size: 11, weight: .bold)).foregroundStyle(coached ? Theme.lime : Theme.muted)
            JIcon("suivant", size: 14).foregroundStyle(Theme.muted)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
    }
}

/// 07 · Refaire un parcours (et voir la séance).
struct RedoRouteView: View {
    @EnvironmentObject private var coach: CoachSession
    @Environment(\.dismiss) private var dismiss
    let workout: HKWorkout
    @ObservedObject var history: WorkoutHistory
    @State private var locations: [CLLocation] = []
    @State private var loaded = false
    @State private var style = 0   // 0 tranquillement, 1 viser un temps, 2 libre
    @State private var showObjective = false
    @State private var pendingGoal: SessionGoal?

    private var coordinates: [CLLocationCoordinate2D] { locations.filter { $0.horizontalAccuracy < 60 }.map(\.coordinate) }
    private var summary: SessionSummary? { SessionSummary.matching(start: workout.startDate, end: workout.endDate) }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Button { dismiss() } label: { HStack(spacing: 6) { JIcon("retour", size: 14); Text("Retour") }.font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.muted) }
                    Text("On y retourne ?").font(.display(30, weight: .black)).foregroundStyle(.white)
                    Text("\(WorkoutKind(activityType: workout.workoutActivityType).label) du \(workout.startDate.formatted(.dateTime.weekday(.wide)))")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    mapCard
                    HStack(spacing: 0) {
                        stat(WorkoutHistory.distanceMeters(workout).map(Formatters.distance) ?? "--", "Distance")
                        stat(Formatters.elapsed(workout.duration), "Durée")
                        stat(relative(workout.startDate), "Dernière sortie")
                    }
                    .card()
                    if let s = summary {
                        HStack(spacing: 14) {
                            if let hr = s.averageHeartRate { Text("\(Int(hr)) bpm moy.") }
                            if let g = s.goalLabel { Text("Objectif \(g) · \(s.goalReached == true ? "atteint" : "non atteint")") }
                            if let f = s.feeling { Text("Ressenti : \(f.label.lowercased())") }
                        }
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                    if coordinates.count >= 2 {
                        JeffreyBubble(text: "Même parcours. Ton objectif du jour ?")
                        HStack(spacing: 8) {
                            styleChip(0, "Tranquillement", "marche")
                            styleChip(1, "Viser un temps", "chronometre")
                            styleChip(2, "Libre", "libre")
                        }
                        PrimaryButton(title: "Refaire ce parcours") {
                            if let ref = ReferenceRoute.make(name: "\(WorkoutKind(activityType: workout.workoutActivityType).label) du \(workout.startDate.formatted(date: .abbreviated, time: .omitted))",
                                                             date: workout.startDate, locations: locations) {
                                ref.save()
                            }
                            showObjective = true
                        }
                    } else if loaded {
                        JeffreyBubble(text: "Pas de tracé GPS pour cette séance, mais on peut refaire le même effort.")
                        PrimaryButton(title: "Refaire cette séance") { showObjective = true }
                    }
                    NavigationLink { WorkoutDetailView(workout: workout, history: history) } label: {
                        Text("Voir la séance").font(.display(15, weight: .black)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 52).background(Capsule().fill(Theme.surfaceRaised))
                    }
                }
                .padding(18)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard !loaded else { return }
            var locs = await history.route(for: workout)
            if locs.count < 2, let local = LocalRoute.matching(start: workout.startDate, end: workout.endDate) { locs = local.locations }
            locations = locs
            loaded = true
        }
        .sheet(isPresented: $showObjective, onDismiss: {
            if let goal = pendingGoal {
                pendingGoal = nil
                dismiss()
                coach.start(kind: WorkoutKind(activityType: workout.workoutActivityType), goal: goal)
            }
        }) {
            ObjectiveView(kind: WorkoutKind(activityType: workout.workoutActivityType), initial: initialGoal) { goal in
                pendingGoal = goal
                showObjective = false
            }
        }
    }

    private var initialGoal: SessionGoal {
        let d = WorkoutHistory.distanceMeters(workout) ?? 0
        switch style {
        case 0: return d > 0 ? SessionGoal(kind: .distance, target: d, note: "tranquillement, même parcours que la dernière fois") : SessionGoal(kind: .duration, target: workout.duration, note: "tranquillement")
        case 1: return SessionGoal(kind: .duration, target: workout.duration, note: "viser un temps : faire au moins aussi bien que \(Formatters.elapsed(workout.duration)) sur ce parcours")
        default: return SessionGoal(kind: .free, target: 0, note: "même parcours, sortie libre")
        }
    }

    private func styleChip(_ i: Int, _ title: String, _ icon: String) -> some View {
        let selected = style == i
        return Button { withAnimation(.snappy) { style = i } } label: {
            VStack(spacing: 4) {
                JIcon(icon, size: 18)
                Text(title).font(.system(size: 11, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Theme.background : .white)
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? Theme.lime : Theme.surface))
        }
    }

    private var mapCard: some View {
        Group {
            if coordinates.count >= 2 {
                Map {
                    MapPolyline(coordinates: coordinates).stroke(Theme.lime, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    if let f = coordinates.first { Annotation("", coordinate: f) { Circle().fill(.white).frame(width: 10, height: 10) } }
                    if let l = coordinates.last { Annotation("", coordinate: l) { JIcon("arrivee", size: 18).foregroundStyle(.white) } }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface).frame(height: 120)
                    .overlay(Text(loaded ? "Pas de tracé" : "Chargement…").font(.caption).foregroundStyle(Theme.muted))
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.display(18, weight: .black).monospacedDigit()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func relative(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Aujourd'hui" }
        if cal.isDateInYesterday(date) { return "Hier" }
        return date.formatted(.dateTime.weekday(.abbreviated).day()).capitalized
    }
}
