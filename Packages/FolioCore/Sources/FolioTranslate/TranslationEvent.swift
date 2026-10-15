import Foundation

/// Progress of one translation job.
public enum TranslationEvent: Sendable, Hashable {
    /// Human-readable (Chinese) stage name, e.g. "翻译段落".
    case stage(String)
    /// Overall progress, 0…1, monotonically non-decreasing.
    case progress(Double)
    case finished(mono: URL?, dual: URL?)
    case failed(message: String, logURL: URL)
    case cancelled
}

/// A decoded `@@FOLIO@@{json}` line from the driver.
struct DriverEvent: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case stage(String)
        case progress(stage: String?, overall: Double?, stageCurrent: Int?, stageTotal: Int?)
        case finish(mono: String?, dual: String?, glossary: String?)
        case error(message: String, type: String?, details: String?)
        case version(String)
        case warmupStart(total: Int)
        case warmupProgress(done: Int, total: Int, file: String?)
        case warmupRetry(attempt: Int, remaining: Int)
        case warmupFinish
        case other(String)
    }

    var kind: Kind

    /// Returns nil for ordinary log lines.
    static func parse(_ line: String) -> DriverEvent? {
        guard let range = line.range(of: DriverScript.eventPrefix) else { return nil }
        let json = line[range.upperBound...]
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        func string(_ key: String) -> String? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            return value as? String ?? "\(value)"
        }
        func double(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        func int(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }

        switch type {
        case "stage":
            return DriverEvent(kind: .stage(string("stage") ?? ""))
        case "progress_start", "progress_update", "progress_end":
            return DriverEvent(kind: .progress(stage: string("stage"), overall: double("overall_progress"),
                                               stageCurrent: int("stage_current"), stageTotal: int("stage_total")))
        case "finish":
            return DriverEvent(kind: .finish(mono: string("mono"), dual: string("dual"), glossary: string("glossary")))
        case "error":
            return DriverEvent(kind: .error(message: string("error") ?? "", type: string("error_type"), details: string("details")))
        case "version":
            return DriverEvent(kind: .version(string("version") ?? ""))
        case "warmup_start":
            return DriverEvent(kind: .warmupStart(total: int("total") ?? 0))
        case "warmup_progress":
            return DriverEvent(kind: .warmupProgress(done: int("done") ?? 0, total: int("total") ?? 0, file: string("file")))
        case "warmup_retry":
            return DriverEvent(kind: .warmupRetry(attempt: int("attempt") ?? 0, remaining: int("remaining") ?? 0))
        case "warmup_finish":
            return DriverEvent(kind: .warmupFinish)
        default:
            return DriverEvent(kind: .other(type))
        }
    }
}

/// Chinese names for driver and BabelDOC stages.
public enum TranslationStageNames {
    static let names: [String: String] = [
        "starting": String(localized: "正在启动翻译引擎", bundle: .module),
        "checking_assets": String(localized: "检查版面模型和字体", bundle: .module),
        "translating": String(localized: "连接翻译服务", bundle: .module),
        "Parse PDF and Create Intermediate Representation": String(localized: "解析 PDF", bundle: .module),
        "DetectScannedFile": String(localized: "检测扫描件", bundle: .module),
        "Parse Page Layout": String(localized: "分析页面版面", bundle: .module),
        "Parse Table": String(localized: "识别表格", bundle: .module),
        "Parse Paragraphs": String(localized: "识别段落", bundle: .module),
        "Parse Formulas and Styles": String(localized: "识别公式和样式", bundle: .module),
        "Remove Char Descent": String(localized: "调整字符基线", bundle: .module),
        "Automatic Term Extraction": String(localized: "提取术语", bundle: .module),
        "Translate Paragraphs": String(localized: "翻译段落", bundle: .module),
        "Typesetting": String(localized: "排版译文", bundle: .module),
        "Add Fonts": String(localized: "嵌入字体", bundle: .module),
        "Generate drawing instructions": String(localized: "生成页面", bundle: .module),
        "Subset font": String(localized: "精简字体", bundle: .module),
        "Save PDF": String(localized: "保存 PDF", bundle: .module),
    ]

    /// Chinese display name for a stage; unknown stages are returned unchanged.
    public static func displayName(for stage: String) -> String {
        names[stage] ?? stage
    }
}
