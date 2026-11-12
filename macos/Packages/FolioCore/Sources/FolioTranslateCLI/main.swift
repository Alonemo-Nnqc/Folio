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
case "agent-models":
    // Every local agent: found where, its version, the models Folio lists for it and the thinking levels it offers.
    for agent in LocalAgent.allCases {
        guard let url = agent.locate(customPath: nil) else { print("\(agent.command): not installed"); continue }
        let version = agent.version(at: url) ?? "?"
        let models = await AgentModels.models(for: agent, executable: url)
        print("\(agent.command) \(version) @ \(url.path)")
        print("   models (\(models.count)): \(models.prefix(12).joined(separator: ", "))")
        print("   levels: \(agent.effortLevels.joined(separator: " ")) default \(agent.defaultEffort ?? "-")")
    }
case "translate":
    // translate <pdf> <output dir> <service> [--pages 1-3] [--to zh] [--field key=value]… [--secret key=value]… [--mono|--dual] [--fresh]
    var fields: [String: String] = [:], secrets: [String: String] = [:]
    var options = TranslationOptions()
    var i = 4
    while i < arguments.count {
        let a = arguments[i]
        func next() -> String { i += 1; return arguments[i] }
        switch a {
        case "--pages": options.pages = next()
        case "--to": options.langOut = next()
        case "--from": options.langIn = next()
        case "--mono": options.outputs = .mono
        case "--dual": options.outputs = .dual
        case "--fresh": options.ignoreCache = true
        case "--concurrency": options.concurrency = Int(next())
        case "--field": let kv = next().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init); fields[kv[0]] = kv[1]
        case "--secret": let kv = next().split(separator: "=", maxSplits: 1).map(String.init); secrets[kv[0]] = kv[1]
        default: break
        }
        i += 1
    }
    let request = TranslationRequest(input: url(arguments[1]), outputDirectory: url(arguments[2]), serviceID: arguments[3],
                                     fieldValues: fields, secrets: secrets, options: options)
    let job = TranslationJob(request: request)
    let start = Date()
    var lastStage = ""
    for await event in job.start() {
        let t = String(format: "%6.1fs", Date().timeIntervalSince(start))
        switch event {
        case .stage(let s): if s != lastStage { lastStage = s; if !s.hasPrefix("翻译段落") || s.hasSuffix("0") { print(t, "stage", s) } }
        case .progress(let value): if arguments.contains("--progress") { print(t, "progress", value) }
        case .preview(let u): print(t, "preview", u.lastPathComponent)
        case .notice(let text): print(t, "notice", text)
        case .finished(let m, let d): print(t, "finished", m?.path ?? "-", d?.path ?? "-")
        case .failed(let message, let log): print(t, "FAILED", message, log.path)
        case .cancelled: print(t, "cancelled")
        }
    }
case "blocks":
    print(EngineDiagnostics.blocks(input: url(arguments[1]), page: Int(arguments[2]) ?? 1, containing: arguments.count > 3 ? arguments[3] : ""))
case "links":
    print(EngineDiagnostics.links(input: url(arguments[1]), pages: arguments.count > 2 ? arguments[2].split(separator: ",").compactMap { Int($0) } : nil))
case "agents":
    // agents [--probe] [service or command]
    print(await EngineDiagnostics.agents(probe: arguments.contains("--probe"), only: arguments.dropFirst().first { !$0.hasPrefix("--") }))
case "marks":
    print(EngineDiagnostics.marks(input: url(arguments[1]), page: Int(arguments[2]) ?? 1))
case "suspects":
    print(EngineDiagnostics.suspects(input: url(arguments[1])))
case "fonts":
    print(EngineDiagnostics.fonts(input: url(arguments[1]), page: Int(arguments[2]) ?? 1))
case "bing":
    print(await EngineDiagnostics.bing(arguments[1]))
case "audit":
    // audit <pdf> <service> [model] [--out file.pdf] [--verbose]
    let out = arguments.firstIndex(of: "--out").map { url(arguments[$0 + 1]) }
    let model = arguments.count > 3 && !arguments[3].hasPrefix("--") ? arguments[3] : ""
    print(try EngineDiagnostics.audit(input: url(arguments[1]), serviceID: arguments[2], model: model, output: out,
                                      verbose: arguments.contains("--verbose")))
case "selection":
    // selection <service> <text> [--to zh]: 划词翻译 of one passage
    let target = arguments.firstIndex(of: "--to").map { arguments[$0 + 1] } ?? "zh"
    do {
        let result = try await SelectionTranslator.translate(arguments[2], serviceID: arguments[1], fields: [:], secrets: [:], from: "en", to: target)
        print(result.text + (result.fellBackFrom.map { "\n(\(result.serviceID) instead of \($0))" } ?? ""))
    } catch {
        print("error: \(error.localizedDescription)")
    }
case "selection-bench":
    // selection-bench <service> [--prewarm] [--delay seconds]: how long 划词翻译 takes, from a cold process.
    // With --prewarm the service is got ready first (as the reader does on mouse-down), and the first passage is sent
    // after --delay seconds (the time a selection takes; 0 = at once), or once the warm-up has finished when no delay is given.
    let service = arguments[1]
    let passages = [
        "Transformers have become the dominant architecture for natural language processing.",
        "We evaluate our method on three benchmarks and report the mean over five runs.",
        "The results suggest that pretraining on larger corpora improves robustness to distribution shift.",
    ]
    func timed(_ label: String, _ text: String) async {
        let start = Date()
        do {
            let result = try await SelectionTranslator.translate(text, serviceID: service, fields: [:], secrets: [:], from: "en", to: "zh", fallback: false)
            print(String(format: "%@: %.0f ms  %@", label, Date().timeIntervalSince(start) * 1000, String(result.text.prefix(24))))
        } catch {
            print(String(format: "%@: %.0f ms  error: %@", label, Date().timeIntervalSince(start) * 1000, error.localizedDescription))
        }
    }
    if arguments.contains("--prewarm") {
        let start = Date()
        if let index = arguments.firstIndex(of: "--delay"), let delay = Double(arguments[index + 1]) {
            SelectionTranslator.prewarm(serviceID: service)
            try await Task.sleep(for: .seconds(delay))
            print(String(format: "selection made after %.0f ms", delay * 1000))
        } else {
            await SelectionTranslator.prewarmed(serviceID: service)
            print(String(format: "prewarm: %.0f ms", Date().timeIntervalSince(start) * 1000))
        }
    }
    await timed("first passage", passages[0])
    await timed("second passage", passages[1])
    try await Task.sleep(for: .seconds(5))
    await timed("third passage, 5 s later", passages[2])
    await timed("first passage again (cache)", passages[0])
case "edit":
    // edit <pdf> <page>: the text blocks of a page (1-based) as the PDF editor sees them.
    // edit <pdf> <page> <block> <text> <out.pdf>: replaces a block's text (`{v1}` … put its formulas back).
    let editor = try PDFTextEditor(data: Data(contentsOf: url(arguments[1])))
    let page = (Int(arguments[2]) ?? 1) - 1
    let blocks = editor.blocks(onPage: page)
    if arguments.count >= 6, let index = Int(arguments[3]), let block = blocks.first(where: { $0.index == index }) {
        let start = Date()
        let data = try editor.replace(block, with: arguments[4])
        try data.write(to: url(arguments[5]))
        print(String(format: "written %d bytes in %.2f s", data.count, Date().timeIntervalSince(start)))
    } else {
        for block in blocks {
            let r = block.rect
            print(String(format: "%3d %@ [%.0f,%.0f %.0f×%.0f] %.1fpt/%.1f %@ %@", block.index, block.isEditable ? "✎" : "·", r.minX, r.minY, r.width, r.height,
                         block.fontSize, block.lineHeight, block.alignment.rawValue, String(block.text.prefix(70))) + (block.reason.map { "  (\($0))" } ?? ""))
        }
    }
default:
    print("usage: folio-translate roundtrip|compare …")
}
