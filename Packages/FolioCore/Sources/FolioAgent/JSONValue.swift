import Foundation

/// A JSON value that is Sendable and Codable — MCP messages, tool arguments and results.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int64(value)) : String(value)
        default: nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .number(let value): Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .string(let value): ["true", "1", "yes"].contains(value.lowercased())
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Strings of an array, or a single string as a one-element list.
    public var stringList: [String] {
        if let array = arrayValue { return array.compactMap(\.stringValue) }
        return stringValue.map { [$0] } ?? []
    }

    public static func from(_ string: String?) -> JSONValue { string.map(JSONValue.string) ?? .null }
    public static func from(_ int: Int?) -> JSONValue { int.map { .number(Double($0)) } ?? .null }

    /// Compact JSON text.
    public func encoded(pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    public static func decode(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}
