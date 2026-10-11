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
        "starting": "正在启动翻译引擎",
        "checking_assets": "检查版面模型和字体",
        "translating": "准备翻译",
        "Parse PDF and Create Intermediate Representation": "解析 PDF",
        "DetectScannedFile": "检测扫描件",
        "Parse Page Layout": "分析页面版面",
        "Parse Table": "识别表格",
        "Parse Paragraphs": "识别段落",
        "Parse Formulas and Styles": "识别公式和样式",
        "Remove Char Descent": "调整字符基线",
        "Automatic Term Extraction": "提取术语",
        "Translate Paragraphs": "翻译段落",
        "Typesetting": "排版译文",
        "Add Fonts": "嵌入字体",
        "Generate drawing instructions": "生成页面",
        "Subset font": "精简字体",
        "Save PDF": "保存 PDF",
    ]

    /// Chinese display name for a stage; unknown stages are returned unchanged.
    public static func displayName(for stage: String) -> String {
        names[stage] ?? stage
    }
}
