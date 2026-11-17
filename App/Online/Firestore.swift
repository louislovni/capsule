import Foundation

/// A Firestore field value (the REST API's typed JSON).
enum FieldValue: Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case timestamp(Date)
    case strings([String])
    case map([String: FieldValue])
    case null

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    var json: [String: Any] {
        switch self {
        case .string(let value): return ["stringValue": value]
        case .bool(let value): return ["booleanValue": value]
        case .int(let value): return ["integerValue": String(value)]
        case .timestamp(let value): return ["timestampValue": Self.iso.string(from: value)]
        case .strings(let values): return ["arrayValue": ["values": values.map { ["stringValue": $0] }]]
        case .map(let fields): return ["mapValue": ["fields": fields.mapValues { $0.json }]]
        case .null: return ["nullValue": NSNull()]
        }
    }

    init(json: Any?) {
        guard let dict = json as? [String: Any] else {
            self = .null
            return
        }
        if let value = dict["stringValue"] as? String {
            self = .string(value)
        } else if let value = dict["booleanValue"] as? Bool {
            self = .bool(value)
        } else if let value = dict["integerValue"] as? String {
            self = .int(Int(value) ?? 0)
        } else if let value = dict["timestampValue"] as? String {
            let plain = ISO8601DateFormatter()
            self = .timestamp(Self.iso.date(from: value) ?? plain.date(from: value) ?? .distantPast)
        } else if let array = dict["arrayValue"] as? [String: Any] {
            let values = (array["values"] as? [[String: Any]]) ?? []
            self = .strings(values.compactMap { $0["stringValue"] as? String })
        } else if let map = dict["mapValue"] as? [String: Any] {
            let fields = (map["fields"] as? [String: Any]) ?? [:]
            self = .map(fields.mapValues { FieldValue(json: $0) })
        } else {
            self = .null
        }
    }

    var stringValue: String? { if case .string(let value) = self { return value } else { return nil } }
    var boolValue: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    var dateValue: Date? { if case .timestamp(let value) = self { return value } else { return nil } }
    var listValue: [String] { if case .strings(let values) = self { return values } else { return [] } }
    var mapValue: [String: FieldValue] { if case .map(let fields) = self { return fields } else { return [:] } }
}

struct FSDocument {
    /// projects/…/documents/collection/id
    let name: String
    let fields: [String: FieldValue]

    var id: String { String(name.split(separator: "/").last ?? "") }

    subscript(key: String) -> FieldValue {
        fields[key] ?? .null
    }

    init(json: [String: Any]) {
        name = (json["name"] as? String) ?? ""
        let raw = (json["fields"] as? [String: Any]) ?? [:]
        fields = raw.mapValues { FieldValue(json: $0) }
    }
}

/// Firestore's REST API, with the signed-in user's token (the database's rules see who asks).
struct Firestore {
    let config: FirebaseConfig
    let auth: AuthSession

    private var root: String {
        "https://firestore.googleapis.com/v1/projects/\(config.projectID)/databases/(default)/documents"
    }

    private func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: "\(root)/\(path)")!
        if !query.isEmpty {
            components.queryItems = query
        }
        return components.url!
    }

    private func call(_ url: URL, method: String, body: Any? = nil) async throws -> (Int, Any?) {
        let token = try await auth.token()
        return try await HTTP.json(url, method: method, body: body, bearer: token)
    }

    private func check(_ status: Int, _ object: Any?) throws {
        guard (200..<300).contains(status) else {
            if status == 403 {
                throw OnlineError.refused("Refusé par le serveur (règles de la base). \(HTTP.message(object))")
            }
            throw OnlineError.server(HTTP.message(object))
        }
    }

    /// The document, or nil when there is none.
    func get(_ path: String) async throws -> FSDocument? {
        let (status, object) = try await call(url(path), method: "GET")
        if status == 404 { return nil }
        try check(status, object)
        return FSDocument(json: (object as? [String: Any]) ?? [:])
    }

    /// Creates `collection/id` (a new id when nil). False when it already exists.
    @discardableResult
    func create(_ collection: String, id: String?, fields: [String: FieldValue]) async throws -> FSDocument? {
        let query = id.map { [URLQueryItem(name: "documentId", value: $0)] } ?? []
        let (status, object) = try await call(url(collection, query), method: "POST",
                                              body: ["fields": fields.mapValues { $0.json }])
        if status == 409 { return nil }
        try check(status, object)
        return FSDocument(json: (object as? [String: Any]) ?? [:])
    }

    /// Sets these fields only (the others stay).
    func update(_ path: String, fields: [String: FieldValue]) async throws {
        let mask = fields.keys.map { URLQueryItem(name: "updateMask.fieldPaths", value: $0) }
        let exists = URLQueryItem(name: "currentDocument.exists", value: "true")
        let (status, object) = try await call(url(path, mask + [exists]), method: "PATCH",
                                              body: ["fields": fields.mapValues { $0.json }])
        try check(status, object)
    }

    /// Writes the whole document (made if missing, replaced if there).
    func set(_ path: String, fields: [String: FieldValue]) async throws {
        let (status, object) = try await call(url(path), method: "PATCH", body: ["fields": fields.mapValues { $0.json }])
        try check(status, object)
    }

    /// The documents of a collection (up to 300).
    func list(_ collection: String) async throws -> [FSDocument] {
        let (status, object) = try await call(url(collection, [URLQueryItem(name: "pageSize", value: "300")]), method: "GET")
        if status == 404 { return [] }
        try check(status, object)
        let docs = ((object as? [String: Any])?["documents"] as? [[String: Any]]) ?? []
        return docs.map { FSDocument(json: $0) }
    }

    func delete(_ path: String) async throws {
        let (status, object) = try await call(url(path), method: "DELETE")
        if status == 404 { return }
        try check(status, object)
    }

    /// The documents of `collection` whose array `field` holds `value`.
    func query(_ collection: String, arrayField field: String, contains value: String) async throws -> [FSDocument] {
        let body: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": collection]],
                "where": ["fieldFilter": [
                    "field": ["fieldPath": field],
                    "op": "ARRAY_CONTAINS",
                    "value": ["stringValue": value],
                ]],
                "limit": 100,
            ],
        ]
        let (status, object) = try await call(URL(string: "\(root):runQuery")!, method: "POST", body: body)
        try check(status, object)
        let rows = (object as? [[String: Any]]) ?? []
        return rows.compactMap { $0["document"] as? [String: Any] }.map { FSDocument(json: $0) }
    }
}
