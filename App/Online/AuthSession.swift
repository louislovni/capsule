import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Signing in: Google's own sign-in page (ASWebAuthenticationSession, OAuth with PKCE, the
/// project's iOS client), then Firebase Auth's REST API turns Google's ID token into the
/// Firebase user the database knows. Firebase's tokens last an hour; the refresh token in
/// the keychain gets new ones.
final class AuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct User: Equatable {
        let uid: String
        let name: String
        let email: String
    }

    private let config: FirebaseConfig
    private var webSession: ASWebAuthenticationSession?
    private var idToken: String?
    private var expiry = Date.distantPast
    private(set) var user: User?

    init(config: FirebaseConfig) {
        self.config = config
    }

    // MARK: - Google

    func signIn() async throws -> User {
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let redirect = "\(config.reversedClientID):/oauth2redirect"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: self.config.reversedClientID) { url, error in
                    if let url = url {
                        continuation.resume(returning: url)
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        continuation.resume(throwing: OnlineError.cancelled)
                    } else {
                        continuation.resume(throwing: error ?? OnlineError.cancelled)
                    }
                }
                session.presentationContextProvider = self
                self.webSession = session
                session.start()
            }
        }
        webSession = nil
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw OnlineError.cancelled
        }
        let (status, object) = try await HTTP.json(URL(string: "https://oauth2.googleapis.com/token")!, form: [
            "code": code,
            "client_id": config.clientID,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard status == 200, let dict = object as? [String: Any], let googleIDToken = dict["id_token"] as? String else {
            throw OnlineError.server(HTTP.message(object))
        }
        return try await firebaseSignIn(googleIDToken: googleIDToken)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    // MARK: - Firebase

    private func firebaseSignIn(googleIDToken: String) async throws -> User {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(config.apiKey)")!
        let (status, object) = try await HTTP.json(url, body: [
            "postBody": "id_token=\(googleIDToken)&providerId=google.com",
            "requestUri": "http://localhost",
            "returnIdpCredential": true,
            "returnSecureToken": true,
        ])
        guard status == 200, let dict = object as? [String: Any],
              let token = dict["idToken"] as? String, let refresh = dict["refreshToken"] as? String,
              let uid = dict["localId"] as? String else {
            throw OnlineError.server(HTTP.message(object))
        }
        let name = (dict["firstName"] as? String) ?? (dict["displayName"] as? String) ?? ""
        let email = (dict["email"] as? String) ?? ""
        store(token: token, refresh: refresh, expiresIn: dict["expiresIn"])
        let signedIn = User(uid: uid, name: name, email: email)
        user = signedIn
        Keychain.write("uid", uid)
        Keychain.write("name", name)
        Keychain.write("email", email)
        return signedIn
    }

    /// Signed in on an earlier launch: back with the stored refresh token.
    func restore() async -> User? {
        guard Keychain.read("refresh") != nil, let uid = Keychain.read("uid") else { return nil }
        user = User(uid: uid, name: Keychain.read("name") ?? "", email: Keychain.read("email") ?? "")
        do {
            _ = try await token()
            return user
        } catch {
            return user   // offline: still signed in, the calls will say so
        }
    }

    func signOut() {
        idToken = nil
        expiry = .distantPast
        user = nil
        for key in ["refresh", "uid", "name", "email"] {
            Keychain.write(key, nil)
        }
    }

    /// A Firebase ID token good for a few more minutes.
    func token() async throws -> String {
        if let token = idToken, expiry.timeIntervalSinceNow > 120 {
            return token
        }
        guard let refresh = Keychain.read("refresh") else { throw OnlineError.refused("Tu n'es plus connecté.") }
        let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(config.apiKey)")!
        let (status, object) = try await HTTP.json(url, form: ["grant_type": "refresh_token", "refresh_token": refresh])
        guard status == 200, let dict = object as? [String: Any], let token = dict["id_token"] as? String else {
            if status == 400 {
                signOut()
                throw OnlineError.refused("Ta session a expiré : reconnecte-toi.")
            }
            throw OnlineError.server(HTTP.message(object))
        }
        store(token: token, refresh: (dict["refresh_token"] as? String) ?? refresh, expiresIn: dict["expires_in"])
        return token
    }

    private func store(token: String, refresh: String, expiresIn: Any?) {
        idToken = token
        let seconds = Double((expiresIn as? String) ?? "") ?? (expiresIn as? Double) ?? 3600
        expiry = Date().addingTimeInterval(seconds)
        Keychain.write("refresh", refresh)
    }

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in characters.randomElement()! })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
