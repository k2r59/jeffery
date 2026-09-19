import Foundation
import AuthenticationServices
import Combine
import UIKit

/// Compte Jeffrey : connexion avec Apple, jeton de session du backend (server/), rôle et quota.
/// Le backend ne voit ni le profil, ni la mémoire, ni la conversation : il délivre des jetons éphémères OpenAI.
enum JeffreyBackend {
    /// URL du Worker (server/README.md). Sans elle, seule la clé perso (BYOK) fonctionne.
    static let baseURL = URL(string: "https://jeffrey-api.dns-d5d.workers.dev")!

    struct User: Codable, Equatable, Identifiable {
        var id: String
        var email: String?
        var name: String?
        var role: String        // admin | allowed | pending | blocked
        var createdAt: String?
        var lastSeenAt: String?
        var sessions: Int?

        var isAdmin: Bool { role == "admin" }
        var canUse: Bool { role == "admin" || role == "allowed" }
        var roleLabel: String {
            switch role {
            case "admin": return "Administrateur"
            case "allowed": return "Autorisé"
            case "pending": return "En attente"
            default: return "Bloqué"
            }
        }
    }
    struct Quota: Codable, Equatable { var used: Int; var limit: Int; var unlimited: Bool }
    struct AuthResponse: Codable { var token: String; var user: User; var quota: Quota? }
    struct MeResponse: Codable { var user: User; var quota: Quota }
    struct SessionResponse: Codable { var clientSecret: String; var expiresAt: Double; var model: String }
    struct APIError: LocalizedError { let status: Int; let message: String; var errorDescription: String? { message } }

    static func request(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = 20
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    static func call<T: Decodable>(_ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil) async throws -> T {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (respData, resp) = try await URLSession.shared.data(for: request(path, method: method, token: token, body: data))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: respData))?["error"] ?? "erreur \(code)"
            throw APIError(status: code, message: message)
        }
        return try JSONDecoder().decode(T.self, from: respData)
    }
}

/// État du compte sur l'iPhone : jeton dans le trousseau, utilisateur en cache, connexion Apple.
@MainActor
final class AccountStore: NSObject, ObservableObject {
    static let shared = AccountStore()
    static let tokenAccount = "jeffrey.session"
    private static let userKey = "account.user"

    @Published private(set) var user: JeffreyBackend.User?
    @Published private(set) var quota: JeffreyBackend.Quota?
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?

    private var signInContinuation: CheckedContinuation<ASAuthorization, Error>?

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.userKey) { user = try? JSONDecoder().decode(JeffreyBackend.User.self, from: data) }
    }

    var token: String? { KeychainStore.read(Self.tokenAccount) }
    var isSignedIn: Bool { token != nil && user != nil }

    /// Connexion avec Apple, puis échange du jeton d'identité contre un jeton Jeffrey.
    func signInWithApple() async {
        error = nil
        isBusy = true
        defer { isBusy = false }
        do {
            let auth = try await requestAppleAuthorization()
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let identityToken = String(data: tokenData, encoding: .utf8) else {
                error = "Apple n'a pas renvoyé de jeton."; return
            }
            let name = [credential.fullName?.givenName, credential.fullName?.familyName].compactMap { $0 }.joined(separator: " ")
            let response: JeffreyBackend.AuthResponse = try await JeffreyBackend.call("auth/apple", method: "POST", body: ["identityToken": identityToken, "fullName": name])
            KeychainStore.write(response.token, account: Self.tokenAccount)
            apply(user: response.user, quota: response.quota)
            if let given = credential.fullName?.givenName, !given.isEmpty, (UserDefaults.standard.string(forKey: Prefs.userName) ?? "").isEmpty {
                UserDefaults.standard.set(given, forKey: Prefs.userName)
            }
        } catch let e as ASAuthorizationError where e.code == .canceled {
            // Annulé par l'utilisateur : rien à dire.
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Rôle et quota à jour (après validation par l'administrateur, par exemple).
    func refresh() async {
        guard let token else { return }
        do {
            let me: JeffreyBackend.MeResponse = try await JeffreyBackend.call("me", token: token)
            apply(user: me.user, quota: me.quota)
        } catch let e as JeffreyBackend.APIError where e.status == 401 {
            signOut()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut() {
        _ = KeychainStore.delete(Self.tokenAccount)
        user = nil
        quota = nil
        UserDefaults.standard.removeObject(forKey: Self.userKey)
    }

    /// Jeton éphémère OpenAI Realtime pour une séance.
    func realtimeClientSecret() async throws -> JeffreyBackend.SessionResponse {
        guard let token else { throw JeffreyBackend.APIError(status: 401, message: "Connecte-toi avec Apple pour lancer une séance.") }
        do {
            return try await JeffreyBackend.call("session", method: "POST", token: token)
        } catch let e as JeffreyBackend.APIError where e.status == 401 {
            signOut()
            throw JeffreyBackend.APIError(status: 401, message: "Session expirée : reconnecte-toi avec Apple.")
        }
    }

    // MARK: Administration

    func adminUsers() async throws -> [JeffreyBackend.User] {
        guard let token else { return [] }
        struct R: Codable { var users: [JeffreyBackend.User] }
        let r: R = try await JeffreyBackend.call("admin/users", token: token)
        return r.users
    }

    func adminSet(role: String, for id: String) async throws -> JeffreyBackend.User {
        guard let token else { throw JeffreyBackend.APIError(status: 401, message: "connexion requise") }
        struct R: Codable { var user: JeffreyBackend.User }
        let r: R = try await JeffreyBackend.call("admin/users/\(id)", method: "POST", token: token, body: ["role": role])
        return r.user
    }

    private func apply(user: JeffreyBackend.User, quota: JeffreyBackend.Quota?) {
        self.user = user
        self.quota = quota
        if let data = try? JSONEncoder().encode(user) { UserDefaults.standard.set(data, forKey: Self.userKey) }
    }

    private func requestAppleAuthorization() async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            signInContinuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
}

extension AccountStore: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in signInContinuation?.resume(returning: authorization); signInContinuation = nil }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in signInContinuation?.resume(throwing: error); signInContinuation = nil }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

/// D'où vient le droit de parler à OpenAI : compte Jeffrey (jeton éphémère du backend) ou clé perso (BYOK, réglage avancé).
enum OpenAIAccess {
    enum Mode { case account, personalKey, none }

    @MainActor static var mode: Mode {
        if AccountStore.shared.isSignedIn { return .account }
        if !(KeychainStore.read(KeychainStore.apiKeyAccount) ?? "").isEmpty { return .personalKey }
        return .none
    }

    @MainActor static var isConfigured: Bool { mode != .none }

    /// Justificatif pour ouvrir le WebSocket Realtime : jeton éphémère (compte) ou clé perso.
    @MainActor static func realtimeCredential() async throws -> (credential: String, model: String?) {
        switch mode {
        case .account:
            let s = try await AccountStore.shared.realtimeClientSecret()
            return (s.clientSecret, s.model)
        case .personalKey:
            return (KeychainStore.read(KeychainStore.apiKeyAccount) ?? "", nil)
        case .none:
            throw JeffreyBackend.APIError(status: 401, message: "Connecte-toi avec Apple (ou renseigne une clé OpenAI dans les réglages avancés).")
        }
    }

    /// Requête vers l'API Responses : via le backend (compte) ou en direct (clé perso).
    @MainActor static func responsesRequest(body: Data) throws -> URLRequest {
        switch mode {
        case .account:
            guard let token = AccountStore.shared.token else { throw JeffreyBackend.APIError(status: 401, message: "connexion requise") }
            return JeffreyBackend.request("openai/responses", method: "POST", token: token, body: body)
        case .personalKey:
            var r = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            r.httpMethod = "POST"
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("Bearer \(KeychainStore.read(KeychainStore.apiKeyAccount) ?? "")", forHTTPHeaderField: "Authorization")
            return r
        case .none:
            throw JeffreyBackend.APIError(status: 401, message: "ni compte ni clé OpenAI")
        }
    }
}
