import Foundation

/// Decodes a JSON value that different sources send as a string, a number or an array of strings.
/// Arrays yield their first element; numbers their decimal representation.
struct LenientString: Decodable, Sendable, Hashable {
    var value: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else if let strings = try? container.decode([LenientString].self) {
            value = strings.lazy.compactMap(\.value).first
        } else {
            value = nil
        }
    }
}

/// Decodes a value that is either a single object or an array of objects (DBLP does this).
struct OneOrMany<Element: Decodable & Sendable>: Decodable, Sendable {
    var values: [Element]

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let many = try? container.decode([Element].self) {
            values = many
        } else if let one = try? container.decode(Element.self) {
            values = [one]
        } else {
            values = []
        }
    }
}

/// CSL / Crossref date: `{"date-parts": [[2024, 5, 1]]}`.
struct DateParts: Decodable, Sendable {
    var parts: [Int]

    private enum CodingKeys: String, CodingKey {
        case dateParts = "date-parts"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? container.decode([[LenientString?]].self, forKey: .dateParts)) ?? []
        parts = (raw.first ?? []).compactMap { $0?.value.flatMap { Int($0) } }
    }
}
