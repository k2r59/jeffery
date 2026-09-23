import SwiftUI
import CoreLocation

/// Liste des tracés GPS gardés sur l'iPhone. Balayer une ligne vers la gauche propose de la supprimer ;
/// la suppression est confirmée. Les séances et leurs tracés dans Santé ne sont pas touchés.
struct RoutesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var routes: [LocalRoute] = []
    @State private var pendingDelete: LocalRoute?
    @State private var confirmDeleteAll = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                if routes.isEmpty {
                    Text("Aucun tracé enregistré.")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 18).padding(.top, 12)
                    Spacer()
                } else {
                    List {
                        ForEach(routes) { route in
                            row(route)
                                .listRowBackground(Color.clear)
                                .listRowSeparatorTint(Theme.creme.opacity(0.08))
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { pendingDelete = route } label: {
                                        Label("Supprimer", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { reload() }
        .confirmationDialog("Supprimer ce parcours ?", isPresented: Binding(get: { pendingDelete != nil },
                                                                           set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                if let route = pendingDelete { LocalRoute.delete(id: route.id) }
                pendingDelete = nil
                reload()
            }
            Button("Annuler", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "\(label($0)) · \(Formatters.distance($0.distance))" } ?? "")
        }
        .confirmationDialog("Effacer les \(routes.count) parcours ?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Tout effacer", role: .destructive) {
                LocalRoute.deleteAll()
                ReferenceRoute.clear()
                reload()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les cartes des séances passées disparaîtront, ainsi que le parcours à refaire. Tes séances dans Santé sont conservées.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { dismiss() } label: {
                HStack(spacing: 6) { JIcon("retour", size: 14); Text("Retour") }
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.muted)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Tes parcours").font(.display(28, weight: .black)).foregroundStyle(Theme.creme)
                Spacer()
                if !routes.isEmpty {
                    Button("Tout effacer") { confirmDeleteAll = true }
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.alerte)
                }
            }
            Text("Balaie une ligne vers la gauche pour la supprimer. Tes séances dans Santé ne sont pas touchées.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 10)
    }

    private func row(_ route: LocalRoute) -> some View {
        HStack(spacing: 12) {
            JIcon("parcours", size: 17).foregroundStyle(Theme.creme)
                .frame(width: 34, height: 34).background(Circle().fill(Theme.surfaceRaised))
            VStack(alignment: .leading, spacing: 2) {
                Text(label(route)).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Text("\(Formatters.distance(route.distance)) · \(Formatters.elapsed(route.end.timeIntervalSince(route.start))) · \(route.points.count) points")
                    .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func label(_ route: LocalRoute) -> String {
        let kind = WorkoutKind(rawValue: route.kind)?.label ?? "Séance"
        return "\(kind) du \(route.start.formatted(date: .abbreviated, time: .shortened))"
    }

    private func reload() { routes = LocalRoute.loadAll() }
}
