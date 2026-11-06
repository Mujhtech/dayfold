import Foundation

/// Lossless provider values. Write payloads are separate dictionaries of only intended fields.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v); case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v); case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v); case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
}

public typealias JSONObject = [String: JSONValue]
extension Dictionary where Key == String, Value == JSONValue {
    public func text(_ key: String, default fallback: String = "") -> String { self[key]?.string ?? fallback }
    public func flag(_ key: String) -> Bool { self[key]?.bool == true }
}

public enum CalendarError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String), unavailable(String), permission(String), staleGeneration, missing, conflict, disk(String), incompatibleSchema
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s), .permission(let s), .disk(let s): s
        case .staleGeneration: "The calendar changed while this operation was running. Refresh and try again."
        case .missing: "This event or calendar is no longer available."
        case .conflict: "Google changed this event while you were editing it. Review both versions."
        case .incompatibleSchema: "This data was created by a newer Dayfold version. Open it with that version."
        }
    }
}
