import SwiftUI

/// Compte Jeffrey : état de son accès, et pour l'administrateur la liste blanche (demandes en attente, autorisés, bloqués).
struct AccessView: View {
    @ObservedObject private var account = AccountStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var users: [JeffreyBackend.User] = []
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        meCard
                        if account.user?.isAdmin == true { adminSection }
                        if let message { Text(message).font(.footnote).foregroundStyle(Theme.ember) }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Accès")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } } }
            .task { await account.refresh(); await loadUsers() }
            .refreshable { await account.refresh(); await loadUsers() }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.lime)
    }

    private var meCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let u = account.user, account.isSignedIn {
                HStack(spacing: 12) {
                    JIcon("profil", size: 22).foregroundStyle(u.canUse ? Theme.lime : Theme.ember)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(u.name ?? u.email ?? "Compte Apple").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        if let e = u.email, u.name != nil { Text(e).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted) }
                    }
                    Spacer()
                    Text(u.roleLabel).font(.system(size: 12, weight: .heavy)).foregroundStyle(u.canUse ? Theme.background : .white)
                        .padding(.horizontal, 10).frame(height: 26).background(Capsule().fill(u.canUse ? Theme.lime : Theme.ember))
                }
                if let q = account.quota {
                    Text(q.unlimited ? "Séances illimitées (administrateur)." : "Aujourd'hui : \(q.used) séance\(q.used > 1 ? "s" : "") sur \(q.limit).")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                }
                Button("Se déconnecter") { account.signOut(); dismiss() }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            } else {
                Text("Pas connecté.").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Text("Refais la configuration (onglet Jeffrey) pour te connecter avec Apple, ou renseigne une clé dans Avancé.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
            }
        }
        .card()
    }

    private var adminSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Utilisateurs").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.creme)
                Spacer()
                if loading { ProgressView().tint(Theme.lime) }
            }
            let pending = users.filter { $0.role == "pending" }
            if !pending.isEmpty {
                Text("EN ATTENTE").font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.ember)
                ForEach(pending) { userRow($0) }
            }
            let others = users.filter { $0.role != "pending" }
            if !others.isEmpty {
                Text("AUTORISÉS ET BLOQUÉS").font(.system(size: 10, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.muted)
                ForEach(others) { userRow($0) }
            }
            if users.isEmpty, !loading { Text("Personne ne s'est encore connecté.").font(.footnote).foregroundStyle(Theme.muted) }
        }
        .card()
    }

    private func userRow(_ u: JeffreyBackend.User) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(u.name ?? u.email ?? u.id).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                Text([u.email, u.sessions.map { "\($0) séance\($0 > 1 ? "s" : "")" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            if u.id == account.user?.id {
                Text("toi").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.muted)
            } else if u.role == "admin" {
                Text("Admin").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.lime)
            } else {
                Menu {
                    Button("Autoriser") { Task { await set("allowed", u) } }
                    Button("Bloquer", role: .destructive) { Task { await set("blocked", u) } }
                    Button("Remettre en attente") { Task { await set("pending", u) } }
                } label: {
                    Text(u.roleLabel).font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(u.canUse ? Theme.background : .white)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(Capsule().fill(u.canUse ? Theme.lime : (u.role == "pending" ? Theme.ember : Theme.surfaceRaised)))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func loadUsers() async {
        guard account.user?.isAdmin == true else { return }
        loading = true
        defer { loading = false }
        do { users = try await account.adminUsers(); message = nil } catch { message = error.localizedDescription }
    }

    private func set(_ role: String, _ u: JeffreyBackend.User) async {
        do {
            let updated = try await account.adminSet(role: role, for: u.id)
            if let i = users.firstIndex(where: { $0.id == updated.id }) { users[i] = updated }
        } catch { message = error.localizedDescription }
    }
}
