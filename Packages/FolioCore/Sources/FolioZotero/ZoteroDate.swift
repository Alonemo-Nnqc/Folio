import Foundation

/// Parses Zotero's two date encodings: SQL timestamps (`items.dateAdded`/`dateModified`) and
/// the "date" field's multipart encoding.
enum ZoteroDate {
    /// Parses a UTC `"YYYY-MM-DD HH:MM:SS"` timestamp, as stored in `items.dateAdded` /
    /// `items.dateModified`.
    static func parseTimestamp(_ s: String) -> Date {
        var year = 1970, month = 1, day = 1, hour = 0, minute = 0, second = 0
        let parts = s.split(separator: " ")
        if parts.count >= 1 {
            let d = parts[0].split(separator: "-")
            if d.count == 3 { year = Int(d[0]) ?? 1970; month = Int(d[1]) ?? 1; day = Int(d[2]) ?? 1 }
        }
        if parts.count >= 2 {
            let t = parts[1].split(separator: ":")
            if t.count == 3 { hour = Int(t[0]) ?? 0; minute = Int(t[1]) ?? 0; second = Int(t[2]) ?? 0 }
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        calendar.timeZone = utc
        components.timeZone = utc
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// Zotero stores the "date" field's value as `"<multipart-sql-date> <original text>"`,
    /// e.g. `"2024-09-00 09/2024"` (September 2024, day unknown) or `"2021-00-00 2021"`
    /// (year only). Returns the year and a `"YYYY[-MM[-DD]]"` normalisation.
    static func parseFieldValue(_ raw: String) -> (year: Int?, normalized: String?) {
        let head = raw.split(separator: " ", maxSplits: 1).first.map(String.init) ?? raw
        let comps = head.split(separator: "-", omittingEmptySubsequences: false)
        guard comps.count == 3, comps[0].count == 4, let year = Int(comps[0]), year > 0 else {
            if let year = firstFourDigitYear(in: raw) { return (year, String(year)) }
            return (nil, nil)
        }
        let month = Int(comps[1]) ?? 0
        let day = Int(comps[2]) ?? 0
        if month <= 0 || month > 12 { return (year, String(year)) }
        if day <= 0 || day > 31 { return (year, String(format: "%04d-%02d", year, month)) }
        return (year, String(format: "%04d-%02d-%02d", year, month, day))
    }

    private static func firstFourDigitYear(in text: String) -> Int? {
        var digits = ""
        for ch in text {
            if ch.isASCII, ch.isNumber {
                digits.append(ch)
                if digits.count == 4 {
                    if let value = Int(digits), value > 1000, value < 3000 { return value }
                    digits.removeFirst()
                }
            } else {
                digits = ""
            }
        }
        return nil
    }
}
