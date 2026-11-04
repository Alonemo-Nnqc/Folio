import CoreGraphics
import Foundation

/// What to do with one operator when a content stream is rewritten.
enum EditAction: Hashable, Sendable {
    /// Leave it out (a `'` or `"` keeps its move to the next line).
    case drop
    /// Draw it invisibly (`3 Tr`), so text after it on the same line keeps its position; `restore` is the
    /// rendering mode to switch back to.
    case hide(restore: Int)
    /// Write these operators instead (a show operator with some glyphs taken out).
    case replace(Data)
}

/// Rewrites interpreted content streams with some operators removed. Forms containing removed operators are
/// written again as new form XObjects; everything else is copied byte for byte.
struct ContentEditor {
    let streams: [StreamPath: InterpretedStream]
    let edits: [OpLocation: EditAction]
    let copier: PDFCopier
    /// Prefix for names of rewritten forms in resource dictionaries.
    var namePrefix = "FolioE"

    private var editedStreams: Set<StreamPath> {
        var result: Set<StreamPath> = []
        for location in edits.keys {
            var path = location.stream
            result.insert(path)
            while !path.isEmpty {
                path.removeLast()
                result.insert(path)
            }
        }
        return result
    }

    /// The page's new content and the resources it needs: the page's own resources plus the rewritten forms.
    func pageContent() -> (content: Data, resources: [String: PDFValue]) {
        let touched = editedStreams
        var counter = 0
        let (data, extra) = rewrite([], touched: touched, counter: &counter)
        return (data, resources(streams[[]]?.resources, adding: extra))
    }

    /// `resources` copied, with extra XObjects merged in.
    func resources(_ source: CGPDFDictionaryRef?, adding extra: [String: PDFValue]) -> [String: PDFValue] {
        var result = source.map { copier.entries(of: $0) } ?? [:]
        guard !extra.isEmpty else { return result }
        var xobjects: [String: PDFValue] = [:]
        if let source, let dict = PDFDictionary.dict(source, "XObject") {
            xobjects = copier.entries(of: dict)
        }
        xobjects.merge(extra) { _, new in new }
        result["XObject"] = .dict(xobjects)
        return result
    }

    private func rewrite(_ path: StreamPath, touched: Set<StreamPath>, counter: inout Int) -> (Data, [String: PDFValue]) {
        guard let stream = streams[path] else { return (Data(), [:]) }
        var out = Data()
        out.reserveCapacity(stream.source.count)
        var extra: [String: PDFValue] = [:]
        for (index, op) in stream.ops.enumerated() {
            let location = OpLocation(stream: path, index: index)
            if let action = edits[location] {
                switch action {
                case .drop:
                    if op.name == "'" {
                        out.append(contentsOf: Array("T*\n".utf8))
                    } else if op.name == "\"", op.operands.count == 3 {
                        let aw = PDFValue.format(op.operands[0].number ?? 0), ac = PDFValue.format(op.operands[1].number ?? 0)
                        out.append(contentsOf: Array("\(aw) Tw \(ac) Tc T*\n".utf8))
                    }
                case .hide(let restore):
                    out.append(contentsOf: Array("3 Tr\n".utf8))
                    out.append(stream.source[op.range])
                    out.append(contentsOf: Array("\n\(restore) Tr\n".utf8))
                case .replace(let data):
                    out.append(data)
                    out.append(0x0A)
                }
                continue
            }
            let formPath = path + [index]
            if op.name == "Do", touched.contains(formPath), let form = streams[formPath], let formStream = form.form {
                let (content, innerExtra) = rewrite(formPath, touched: touched, counter: &counter)
                var dict: [String: PDFValue] = [:]
                if let source = CGPDFStreamGetDictionary(formStream) {
                    dict = copier.entries(of: source, skipping: ["Length", "Filter", "DecodeParms", "Resources"])
                }
                dict["Resources"] = .dict(resources(form.resources, adding: innerExtra))
                let number = copier.writer.addStream(dict: dict, data: content)
                counter += 1
                let name = "\(namePrefix)\(counter)"
                extra[name] = .ref(number)
                out.append(contentsOf: Array("/\(name) Do\n".utf8))
                continue
            }
            out.append(stream.source[op.range])
            out.append(0x0A)
        }
        return (out, extra)
    }
}
