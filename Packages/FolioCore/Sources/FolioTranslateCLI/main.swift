import Foundation
import FolioTranslate

// `folio-translate` — developer tool for the native translation engine.
let arguments = Array(CommandLine.arguments.dropFirst())
func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

switch arguments.first {
case "roundtrip":
    let start = Date()
    try EngineDiagnostics.roundTrip(input: url(arguments[1]), output: url(arguments[2]), reemit: arguments.contains("--reemit"))
    print(String(format: "written in %.2f s", Date().timeIntervalSince(start)))
case "compare":
    let diffs = EngineDiagnostics.compare(url(arguments[1]), url(arguments[2]))
    for (i, d) in diffs.enumerated() { print(String(format: "page %d: %.4f%%", i + 1, d * 100)) }
case "layout":
    let pages = arguments.count > 3 ? arguments[3].split(separator: ",").compactMap { Int($0) } : nil
    print(try EngineDiagnostics.layout(input: url(arguments[1]), outputDirectory: url(arguments[2]), pages: pages))
case "runs":
    print(EngineDiagnostics.runs(input: url(arguments[1]), page: Int(arguments[2]) ?? 1))
case "fake":
    let pages = arguments.count > 3 ? arguments[3].split(separator: ",").compactMap { Int($0) } : nil
    print(try EngineDiagnostics.fakeTranslate(input: url(arguments[1]), outputDirectory: url(arguments[2]), pages: pages))
case "snapshot":
    let pages = arguments[3].split(separator: ",").compactMap { Int($0) }
    try EngineDiagnostics.snapshot(input: url(arguments[1]), outputDirectory: url(arguments[2]), pages: pages)
case "segments":
    print(EngineDiagnostics.segments(input: url(arguments[1]), page: Int(arguments[2]) ?? 1, containing: arguments.count > 3 ? arguments[3] : ""))
case "lines":
    print(EngineDiagnostics.lines(input: url(arguments[1]), page: Int(arguments[2]) ?? 1, minY: Double(arguments[3]) ?? 0, maxY: Double(arguments[4]) ?? 1000))
default:
    print("usage: folio-translate roundtrip|compare …")
}
