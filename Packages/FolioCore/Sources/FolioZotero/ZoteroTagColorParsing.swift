import Foundation

/// Parses the `tagColors` `syncedSettings` value into a lookup usable regardless of the
/// tag name's case.
enum ZoteroTagColorParsing {
    /// The colour Folio assigns to a tag with no entry in `tagColors` (matches the app's tag
    /// palette default).
    static let defaultColorHex = "#8E8E93"

    private struct Entry: Decodable {
        let name: String
        let color: String
    }

    /// Parses `[{"name": "...", "color": "#RRGGBB"}, ...]` into a lowercased-name -> colorHex map.
    static func parse(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        var result: [String: String] = [:]
        for entry in entries { result[entry.name.lowercased()] = entry.color }
        return result
    }
}
