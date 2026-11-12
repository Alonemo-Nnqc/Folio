import Foundation
import GRDB

/// A journal's ranks from easyScholar (META-30): the dataset abbreviations of its open API (`sciUp`, `sci`,
/// `sciif`…) mapped to their texts ("医学1区", "Q1", "12.3"), cached per journal for 30 days. An empty `ranks`
/// means easyScholar does not list the journal.
///
/// The Windows app stores and reads the same table (`journalMetrics`) with the same parsing rules.
public struct JournalMetrics: Sendable, Hashable, Codable {
    public var ranks: [String: String]
    public var fetchedAt: Date

    public init(ranks: [String: String], fetchedAt: Date = Date()) {
        self.ranks = ranks
        self.fetchedAt = fetchedAt
    }

    /// How long a cached answer stays valid.
    public static let maximumAge: TimeInterval = 30 * 24 * 3600

    public var isIndexed: Bool { !ranks.isEmpty }

    public func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) < Self.maximumAge && fetchedAt <= now.addingTimeInterval(24 * 3600)
    }

    private func value(_ key: String) -> String? {
        guard let text = ranks[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    // MARK: Parsed fields

    /// 中科院分区升级版 (`sciUp`): zone 1…4.
    public var casZone: Int? { value("sciUp").flatMap(Self.zone) }
    /// Its subject ("医学" in "医学1区").
    public var casCategory: String? { value("sciUp").flatMap(Self.category) }
    /// 中科院 Top journal (`sciUpTop`, or "Top" in the zone text).
    public var casTop: Bool {
        value("sciUpTop") != nil || (value("sciUp")?.range(of: "top", options: .caseInsensitive) != nil)
    }
    /// 中科院分区基础版 (`sciBase`).
    public var casBaseZone: Int? { value("sciBase").flatMap(Self.zone) }
    public var casBaseCategory: String? { value("sciBase").flatMap(Self.category) }
    /// 中科院升级版小类 (`sciUpSmall`), as easyScholar writes it.
    public var casSmall: String? { value("sciUpSmall") }
    /// JCR quartile (`sci`): 1…4.
    public var jcrQuartile: Int? { value("sci").flatMap(Self.quartile) }
    /// SSCI quartile (`ssci`).
    public var ssciQuartile: Int? { value("ssci").flatMap(Self.quartile) }
    /// Journal Impact Factor (`sciif`).
    public var impactFactor: Double? { value("sciif").flatMap(Self.number) }
    /// Five-year Impact Factor (`sciif5`).
    public var impactFactor5Year: Double? { value("sciif5").flatMap(Self.number) }
    /// JCI (`jci`).
    public var jci: Double? { value("jci").flatMap(Self.number) }
    /// CCF recommendation (`ccf`): "A", "B" or "C".
    public var ccf: String? { value("ccf").flatMap(Self.ccfClass) }
    /// EI Compendex (`eii`).
    public var isEI: Bool { value("eii") != nil }
    /// 中科院预警 (`sciwarn`).
    public var warning: String? { value("sciwarn") }
    /// 北大核心 (`pku`), 南大核心 CSSCI (`cssci`), CSCD (`cscd`).
    public var pku: Bool { value("pku") != nil }
    public var cssci: Bool { value("cssci") != nil }
    public var cscd: Bool { value("cscd") != nil }

    // MARK: Lenient parsing (values are free text: "医学1区", "Q1", "12.3", "CCF-A")

    static func zone(_ text: String) -> Int? {
        if let match = text.firstMatch(of: /([1-4])\s*区/) { return Int(match.1) }
        let digits = text.filter(\.isNumber)
        if digits.count == 1, let value = Int(digits), (1...4).contains(value) { return value }
        return nil
    }

    static func category(_ text: String) -> String? {
        guard let match = text.firstMatch(of: /^(.*?)\s*[1-4]\s*区/) else { return nil }
        let name = String(match.1).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    static func quartile(_ text: String) -> Int? {
        if let match = text.firstMatch(of: /[Qq]\s*([1-4])/) { return Int(match.1) }
        let digits = text.filter(\.isNumber)
        if digits.count == 1, let value = Int(digits), (1...4).contains(value) { return value }
        return nil
    }

    static func number(_ text: String) -> Double? {
        guard let match = text.firstMatch(of: /\d+(?:\.\d+)?/) else { return nil }
        return Double(match.0)
    }

    static func ccfClass(_ text: String) -> String? {
        let rest = text.uppercased().replacingOccurrences(of: "CCF", with: "")
        return rest.first(where: { "ABC".contains($0) }).map(String.init)
    }

    // MARK: Sorting

    /// "分区" column order: 中科院 zone (Top first within a zone), then JCR quartile for journals without one.
    public var rankSortKey: Double? {
        if let zone = casZone { return Double(zone * 10 + (casTop ? 0 : 5)) }
        if let quartile = jcrQuartile { return Double(100 + quartile * 10) }
        return nil
    }

    // MARK: Badges

    public enum BadgeKind: Sendable, Hashable {
        /// 中科院 zone 1…4.
        case cas(Int)
        /// JCR / SSCI quartile 1…4.
        case quartile(Int)
        case impactFactor, impactFactor5Year, ccf, index, warning
    }

    public struct Badge: Sendable, Hashable, Identifiable {
        public var kind: BadgeKind
        public var text: String
        /// Full explanation for the tooltip.
        public var detail: String
        public var emphasized = false
        public var id: String { text }
    }

    /// The capsules under the journal name, most telling first.
    public var badges: [Badge] {
        var list: [Badge] = []
        if let zone = casZone {
            let top = casTop
            var text = String(localized: "中科院 \(zone) 区", bundle: .module)
            if top { text += " Top" }
            var lines = [String(localized: "中科院分区（升级版）：\(Self.zoneText(casCategory, zone))", bundle: .module)
                         + (top ? String(localized: "，Top 期刊", bundle: .module) : "")]
            if let base = casBaseZone {
                lines.append(String(localized: "中科院分区（基础版）：\(Self.zoneText(casBaseCategory, base))", bundle: .module))
            }
            if let small = casSmall { lines.append(String(localized: "小类：\(small)", bundle: .module)) }
            list.append(Badge(kind: .cas(zone), text: text, detail: lines.joined(separator: "\n"), emphasized: top))
        } else if let base = casBaseZone {
            list.append(Badge(kind: .cas(base), text: String(localized: "中科院 \(base) 区", bundle: .module),
                              detail: String(localized: "中科院分区（基础版）：\(Self.zoneText(casBaseCategory, base))", bundle: .module)))
        }
        if let quartile = jcrQuartile {
            list.append(Badge(kind: .quartile(quartile), text: "JCR Q\(quartile)",
                              detail: String(localized: "JCR 分区（Clarivate）：Q\(quartile)", bundle: .module)))
        }
        if let value = impactFactor {
            list.append(Badge(kind: .impactFactor, text: "IF \(Self.format(value))",
                              detail: String(localized: "影响因子（JCR）：\(Self.format(value))", bundle: .module)))
        }
        if let value = impactFactor5Year {
            list.append(Badge(kind: .impactFactor5Year, text: String(localized: "5 年 IF \(Self.format(value))", bundle: .module),
                              detail: String(localized: "5 年影响因子（JCR）：\(Self.format(value))", bundle: .module)))
        }
        if let quartile = ssciQuartile {
            list.append(Badge(kind: .quartile(quartile), text: "SSCI Q\(quartile)",
                              detail: String(localized: "SSCI 分区（Clarivate）：Q\(quartile)", bundle: .module)))
        }
        if let ccf {
            list.append(Badge(kind: .ccf, text: "CCF \(ccf)",
                              detail: String(localized: "中国计算机学会推荐：\(ccf) 类", bundle: .module)))
        }
        if isEI { list.append(Badge(kind: .index, text: "EI", detail: String(localized: "EI 检索", bundle: .module))) }
        if cssci { list.append(Badge(kind: .index, text: "CSSCI", detail: String(localized: "南大核心（CSSCI）", bundle: .module))) }
        if pku {
            list.append(Badge(kind: .index, text: String(localized: "北大核心", bundle: .module),
                              detail: String(localized: "北大中文核心期刊", bundle: .module)))
        }
        if cscd { list.append(Badge(kind: .index, text: "CSCD", detail: String(localized: "中国科学引文数据库", bundle: .module))) }
        if let warning {
            list.append(Badge(kind: .warning, text: String(localized: "预警", bundle: .module),
                              detail: String(localized: "中科院国际期刊预警名单：\(warning)", bundle: .module)))
        }
        return list
    }

    /// One line for tooltips, copies and AI tools: "中科院 1 区 Top · JCR Q1 · IF 12.3".
    public var summary: String {
        badges.map(\.text).joined(separator: " · ")
    }

    /// The "分区" column: the 中科院 zone, else the JCR quartile.
    public var rankText: String? {
        if let zone = casZone { return String(localized: "\(zone) 区", bundle: .module) + (casTop ? " Top" : "") }
        if let base = casBaseZone { return String(localized: "\(base) 区", bundle: .module) }
        if let quartile = jcrQuartile { return "Q\(quartile)" }
        return nil
    }

    static func zoneText(_ category: String?, _ zone: Int) -> String {
        let zoneText = String(localized: "\(zone) 区", bundle: .module)
        return category.map { "\($0) \(zoneText)" } ?? zoneText
    }

    /// "12.3", "0.85", "105" — at most three decimals, no trailing zeros.
    public static func format(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: Journal names

    /// The cache key of a journal name: case, spacing, "&amp;" and trailing dots do not matter.
    public static func key(for name: String) -> String {
        var text = name.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while let last = text.last, last == "." || last == "," || last == ";" { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The name sent to easyScholar: trimmed, "&amp;" decoded, spaces collapsed.
    public static func queryName(for name: String) -> String {
        name.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Venues easyScholar does not rank (preprint servers).
    private static let unrankedVenues: Set<String> = ["arxiv", "biorxiv", "medrxiv", "chemrxiv", "ssrn", "research square",
                                                       "preprints", "techrxiv", "openreview", "psyarxiv", "osf preprints"]

    /// The journal name an item's metrics are looked up by, or nil when it has none worth asking about.
    public static func journalName(of item: Item) -> String? {
        guard item.kind == .regular, item.type == .journalArticle || item.type == .conferencePaper,
              let source = item.source?.trimmingCharacters(in: .whitespacesAndNewlines), source.count >= 2 else { return nil }
        let key = key(for: source)
        guard !key.isEmpty, !unrankedVenues.contains(key), !key.hasPrefix("arxiv") else { return nil }
        return source
    }
}

/// Row of the `journalMetrics` table: the normalised journal name, the ranks as JSON, when they were fetched.
struct JournalMetricsRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "journalMetrics"
    var name: String
    var json: String
    var fetchedAt: Date

    var metrics: JournalMetrics {
        let ranks = (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
        return JournalMetrics(ranks: ranks, fetchedAt: fetchedAt)
    }

    init(name: String, metrics: JournalMetrics) {
        self.name = name
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        json = (try? encoder.encode(metrics.ranks)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        fetchedAt = metrics.fetchedAt
    }
}
