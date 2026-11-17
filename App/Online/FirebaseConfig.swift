import Foundation
import Security

/// The Firebase project the app signs in to: GoogleService-Info.plist, put in the app by the
/// build (from the repository's secret). Without it, accounts are simply off.
struct FirebaseConfig {
    let apiKey: String
    let projectID: String
    /// Google's OAuth client for iOS (Firebase made it when the iOS app was added).
    let clientID: String
    let reversedClientID: String

    static let shared: FirebaseConfig? = {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let apiKey = plist["API_KEY"] as? String,
              let projectID = plist["PROJECT_ID"] as? String,
              let clientID = plist["CLIENT_ID"] as? String,
              let reversed = plist["REVERSED_CLIENT_ID"] as? String else {
            return nil
        }
        return FirebaseConfig(apiKey: apiKey, projectID: projectID, clientID: clientID, reversedClientID: reversed)
    }()
}

/// The refresh token, kept in the keychain (stays signed in between launches).
enum Keychain {
    private static let service = "app.capsule.account"

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value = value else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

enum OnlineError: LocalizedError {
    case notConfigured
    case cancelled
    case server(String)
    case notFound(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Les comptes ne sont pas encore configurés dans cette version de l'app."
        case .cancelled: return "Connexion annulée."
        case .server(let message): return "Erreur du serveur : \(message)"
        case .notFound(let message): return message
        case .refused(let message): return message
        }
    }
}

/// A small JSON request helper.
enum HTTP {
    static func json(_ url: URL, method: String = "POST", body: Any? = nil, form: [String: String]? = nil,
                     bearer: String? = nil) async throws -> (Int, Any?) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if let bearer = bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let form = form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form.map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .formValue) ?? value)"
            }.joined(separator: "&").data(using: .utf8)
        } else if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        return (status, object)
    }

    /// The message in a Google API error body.
    static func message(_ object: Any?) -> String {
        if let dict = object as? [String: Any] {
            if let error = dict["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let description = dict["error_description"] as? String {
                return description
            }
            if let error = dict["error"] as? String {
                return error
            }
        }
        return "réponse inattendue"
    }
}

private extension CharacterSet {
    static let formValue: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
