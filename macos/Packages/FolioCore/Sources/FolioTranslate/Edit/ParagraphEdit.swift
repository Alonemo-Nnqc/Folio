import CoreGraphics
import CoreText
import Foundation

/// A paragraph of a page opened for editing (EDIT-01), changed in place: what is not touched stays exactly as drawn.
///
/// The paragraph is a row of *atoms*: its glyphs as they are (each keeps its font, size, colour and the kerning to
/// its neighbours), the spaces between words, the ends of its lines (a space, nothing between Chinese characters, or a
/// hyphen that breaks a word and shows only where a line ends), its formulas and citations (moved whole, never cut),
/// and the characters typed. A character typed is drawn in the font of the text beside it, with a glyph that font
/// already draws on the page; only a character no font of the page has falls back to a system font in the same style.
///
/// Laying it out keeps every line before the first change as it is; from there the words are set again on the
/// original lines — same left edge, right edge, baseline and alignment, justified lines justified — and as soon as a
/// line ends where it ended before and nothing after it changed, the rest stays as it is. Lines added go below at
/// the paragraph's line spacing. The Windows editor does the same (Folio.Core Translate/Edit/ParagraphEdit.cs).
public final class PDFParagraph: @unchecked Sendable {
    // MARK: Atoms

    struct Atom: Sendable, Hashable {
        enum Kind: Sendable, Hashable {
            /// A character of the page (index into `chars`).
            case char(Int)
            /// A space between words as it was.
            case space(Int)
            /// Where a line of the page ended: a space between words, or nothing (between CJK characters, after a dash).
            case lineEnd(spaced: Bool)
            /// A hyphen that broke a word at a line's end (index into `chars`): drawn only where a line ends on it.
            case softHyphen(Int)
            /// A formula or citation (index into `formulas`): moved whole.
            case formula(Int)
            case typed(String)
            case typedSpace
        }
        var kind: Kind
        /// The line of the page it was on (typed: the line it was typed into); for telling what changed.
        var line: Int
        /// Original atoms: their place in the original row (unchanged runs of the row are recognised by it).
        var original: Int?
    }

    /// What the editor holds: kept for undo and redo inside an editing session.
    public struct State: Sendable, Equatable {
        var atoms: [Atom]
        var dirty: Set<Int>
    }

    public let page: Int
    public let block: Int
    let lines: [LayoutLine]
    /// The page's characters of this paragraph, line by line (flattened), and the line each is on.
    let chars: [PageChar]
    let charLine: [Int]
    let formulas: [FormulaSpan]
    let originalAtoms: [Atom]
    private(set) var state: State
    let interpreter: ContentInterpreter
    let mediaBox: CGRect
    let size: Double
    let pitch: Double
    let centered: Bool
    let justified: Bool
    let naturalSpace: Double
    /// The word space the page's justified lines have, most of them: what a line set again should look like.
    let typicalSpace: Double
    /// How far the page itself squeezed the spaces of its tightest line (a share of the natural space): a line set
    /// again may be squeezed as far.
    let pageShrink: Double
    let columnLeft: Double
    let columnRight: Double
    /// Glyphs of the page that may be borrowed for a typed character: font → text → glyph.
    private let donors: [Int: [String: Int]]

    /// How low the paragraph may reach: the top of what is under it in its column (or the page's bottom margin).
    let floor: Double

    init(page: Int, block index: Int, layoutBlock block: LayoutBlock, formulas spans: [FormulaSpan], interpreter: ContentInterpreter, mediaBox: CGRect,
         floor: Double) {
        self.floor = floor
        self.page = page
        self.block = index
        self.interpreter = interpreter
        self.mediaBox = mediaBox
        lines = block.lines
        size = block.size
        pitch = block.pitch
        centered = block.isCentered
        // Formula pieces (a citation broken over a line is two pieces), each moved whole.
        var pieces: [FormulaSpan] = []
        for span in spans {
            var main = span
            main.continuation = []
            pieces.append(main)
            pieces += span.continuation
        }
        formulas = pieces
        let pieceGlyphs = pieces.map { Set($0.glyphs) }

        var chars: [PageChar] = [], charLine: [Int] = [], atoms: [Atom] = []
        for (li, line) in block.lines.enumerated() {
            var placedPieces = Set<Int>()
            for c in line.chars {
                let ci = chars.count
                chars.append(c)
                charLine.append(li)
                if c.isSpace {
                    if case .space? = atoms.last?.kind {} else { atoms.append(Atom(kind: .space(ci), line: li)) }
                    continue
                }
                if !c.glyphs.isEmpty, let p = pieceGlyphs.firstIndex(where: { $0.isSuperset(of: c.glyphs) }) {
                    if placedPieces.insert(p).inserted { atoms.append(Atom(kind: .formula(p), line: li)) }
                    continue
                }
                atoms.append(Atom(kind: .char(ci), line: li))
            }
            // Spaces at a line's end belong to the break.
            while case .space? = atoms.last?.kind { atoms.removeLast() }
            guard li < block.lines.count - 1 else { continue }
            let next = block.lines[li + 1].chars.first { !$0.isSpace }?.text.first
            if case .char(let last)? = atoms.last?.kind, chars[last].text == "-" || chars[last].text == "\u{2010}",
               atoms.count >= 2, case .char(let before) = atoms[atoms.count - 2].kind, chars[before].text.last?.isLetter == true,
               next?.isLowercase == true {
                atoms[atoms.count - 1].kind = .softHyphen(last)
                atoms.append(Atom(kind: .lineEnd(spaced: false), line: li))
            } else {
                let lastText = atoms.last.flatMap { atom -> String? in
                    if case .char(let c) = atom.kind { return chars[c].text }
                    return nil
                } ?? ""
                let cjk = Self.isCJK(lastText.unicodeScalars.last) && Self.isCJK(next.flatMap { $0.unicodeScalars.first })
                let dash = lastText == "-" || lastText == "–" || lastText == "—" || lastText == "/"
                atoms.append(Atom(kind: .lineEnd(spaced: !cjk && !dash), line: li))
            }
        }
        for i in atoms.indices { atoms[i].original = i }
        self.chars = chars
        self.charLine = charLine
        originalAtoms = atoms
        state = State(atoms: atoms, dirty: [])

        // The column: where lines start (the first may be set in) and end.
        let lefts = block.lines.map(\.minX), rights = block.lines.map(\.maxX)
        columnLeft = lefts.count > 1 ? lefts.dropFirst().min()! : lefts[0]
        columnRight = rights.max()!
        let full = block.lines.dropLast().filter { $0.maxX >= rights.max()! - block.size * 0.6 }.count
        justified = block.lines.count >= 2 && Double(full) >= Double(block.lines.count - 1) * 0.7 && !block.isCentered

        // The word spaces as the page sets them: from the end of the word before to the start of the next.
        func gaps(_ line: LayoutLine) -> [Double] {
            var result: [Double] = []
            let chars = line.chars
            for k in chars.indices where chars[k].isSpace {
                guard let before = chars[..<k].last(where: { !$0.isSpace }), let after = chars[(k + 1)...].first(where: { !$0.isSpace }),
                      k == 0 || !chars[k - 1].isSpace else { continue }
                let gap = after.rect.minX - before.rect.maxX
                if gap > 0 { result.append(gap) }
            }
            return result
        }
        // The natural word space: what the last (unstretched) line uses, else the tightest of the justified lines.
        let lastGaps = block.lines.last.map(gaps) ?? []
        let fullGaps = block.lines.dropLast().flatMap(gaps)
        let guess = lastGaps.sorted().dropFirst(lastGaps.count / 2).first ?? fullGaps.min() ?? block.size * 0.3
        naturalSpace = min(max(guess, block.size * 0.18), block.size * 0.45)
        // What the justified lines have, most of them.
        let median = fullGaps.sorted().dropFirst(fullGaps.count / 2).first ?? naturalSpace
        typicalSpace = justified ? min(max(median, naturalSpace), block.size * 0.6) : naturalSpace
        let means = block.lines.dropLast().map(gaps).filter { !$0.isEmpty }.map { $0.reduce(0, +) / Double($0.count) }
        pageShrink = min(1, max(0.5, (means.min() ?? naturalSpace) / naturalSpace))

        // Glyphs to borrow: every glyph of the page with plain text, by font.
        var donors: [Int: [String: Int]] = [:]
        for (g, glyph) in interpreter.glyphs.enumerated() where glyph.isVisible && glyph.reliable && glyph.isHorizontal && glyph.font >= 0 {
            guard let text = glyph.text, !text.isEmpty, donors[glyph.font]?[text] == nil else { continue }
            donors[glyph.font, default: [:]][text] = g
            // Text extracted as a compatibility character (a Kangxi radical for 文) draws the ideograph typed.
            let plain = text.precomposedStringWithCompatibilityMapping
            if plain != text, donors[glyph.font]?[plain] == nil { donors[glyph.font]![plain] = g }
        }
        self.donors = donors
    }

    static func isCJK(_ scalar: Unicode.Scalar?) -> Bool {
        guard let v = scalar?.value else { return false }
        return (0x2E80...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }

    // MARK: Editing

    public var count: Int { state.atoms.count }
    public var isModified: Bool { !state.dirty.isEmpty && state.atoms != originalAtoms }
    public var snapshot: State {
        get { state }
        set { state = newValue; laidOut = nil }
    }

    func text(of atom: Atom) -> String {
        switch atom.kind {
        case .char(let c): chars[c].text
        case .space, .typedSpace: " "
        case .lineEnd(let spaced): spaced ? " " : ""
        case .softHyphen: ""
        case .formula(let p): chars.indices.filter { !chars[$0].isSpace && Set(formulas[p].glyphs).isSuperset(of: chars[$0].glyphs) && !chars[$0].glyphs.isEmpty }
            .map { chars[$0].text }.joined()
        case .typed(let s): s
        }
    }

    /// The text of `range` (copying).
    public func string(_ range: Range<Int>) -> String {
        state.atoms[range.clamped(to: 0..<count)].map(text).joined()
    }

    public var string: String { string(0..<count) }

    /// The atoms showing `needle` (its first occurrence in the paragraph's text), for tests and tools.
    public func range(of needle: String) -> Range<Int>? {
        var offsets: [Int] = []   // character offset where each atom starts
        var text = ""
        for atom in state.atoms {
            offsets.append(text.count)
            text += self.text(of: atom)
        }
        guard let found = text.range(of: needle) else { return nil }
        let lower = text.distance(from: text.startIndex, to: found.lowerBound), upper = text.distance(from: text.startIndex, to: found.upperBound)
        let start = offsets.firstIndex { $0 >= lower } ?? count
        let end = offsets.firstIndex { $0 >= upper } ?? count
        return start..<max(start, end)
    }

    /// The page's lines drawn again by the edit so far (tests and tools).
    public var rewrittenLines: [Int] { layout.rewritten.sorted() }

    /// Whether the caret stops before atom `index` (not inside a line end that shows nothing).
    public func isStop(_ index: Int) -> Bool {
        guard index > 0, index < count else { return true }
        return !text(of: state.atoms[index - 1]).isEmpty || {
            if case .lineEnd = state.atoms[index - 1].kind { return false }
            if case .softHyphen = state.atoms[index - 1].kind { return false }
            return true
        }()
    }

    /// Replaces `range` with `text` (typed characters take the style of what is beside them when drawn).
    public func replace(_ range: Range<Int>, with text: String) {
        let range = range.clamped(to: 0..<count)
        var atoms = state.atoms
        let neighbour = range.lowerBound > 0 ? atoms[range.lowerBound - 1] : (range.lowerBound < atoms.count ? atoms[range.lowerBound] : nil)
        let line = neighbour?.line ?? 0
        var dirty = state.dirty
        for atom in atoms[range] { dirty.insert(atom.line) }
        dirty.insert(line)
        if range.lowerBound < atoms.count { dirty.insert(atoms[range.lowerBound].line) }
        var typed: [Atom] = []
        for ch in text where ch != "\n" && ch != "\r" {
            typed.append(Atom(kind: ch == " " || ch == "\u{00A0}" || ch == "\t" ? .typedSpace : .typed(String(ch)), line: line))
        }
        // Two spaces never stand together.
        atoms.replaceSubrange(range, with: typed)
        state = State(atoms: atoms, dirty: dirty)
        laidOut = nil
    }

    // MARK: Layout

    /// Where an atom ends up.
    struct Placed {
        var atom: Int
        var x: Double
        var width: Double
        /// Drawn (a hyphen hidden inside a line, a space or a line end draws nothing).
        var visible: Bool
        /// A word broken here by hyphenation: a hyphen is drawn after it.
        var hyphenAfter = false
    }

    struct Line {
        var baseline: Double
        var items: [Placed]
        /// The page's line `original`, exactly as it was: nothing to redraw.
        var untouched: Bool
        var original: Int?
    }

    struct Result {
        var lines: [Line]
        /// The page's lines drawn again (their glyphs are taken out of the page).
        var rewritten: Set<Int>
        /// It reaches below `floor` even set tight: it runs into what is under it.
        var overflows = false
    }

    private var laidOut: Result?

    var layout: Result {
        if let laidOut { return laidOut }
        // As the page sets it; if that runs into what is below, with tighter spaces; then with the lines drawn again a
        // little closer together (never the lines before the change).
        var result = makeLayout(shrink: min(0.8, pageShrink * 0.98), pitch: pitch)
        if reachesBelowFloor(result) { result = makeLayout(shrink: min(0.66, pageShrink * 0.95), pitch: pitch) }
        if reachesBelowFloor(result), let first = state.dirty.min(), first < lines.count {
            let count = result.lines.count
            let room = lines[first].baseline - (floor + size * 0.3)
            if count - 1 > first, room > 0 {
                let tighter = max(pitch * 0.88, room / Double(count - 1 - first))
                if tighter < pitch { result = makeLayout(shrink: min(0.66, pageShrink * 0.95), pitch: tighter) }
            }
            result.overflows = reachesBelowFloor(result)
        }
        laidOut = result
        return result
    }

    private func reachesBelowFloor(_ result: Result) -> Bool {
        guard let last = result.lines.last, result.lines.count > lines.count else { return false }
        return last.baseline - size * 0.25 < floor
    }

    /// Whether the edit runs the paragraph into what is under it (the editor says so).
    public var overflows: Bool { layout.overflows }

    /// The atoms of the page's line `li`, in order (its line end left out).
    private func originalLine(_ li: Int) -> [Int] {
        originalAtoms.indices.filter { originalAtoms[$0].line == li && !Self.isLineEnd(originalAtoms[$0]) }
    }

    static func isLineEnd(_ atom: Atom) -> Bool {
        if case .lineEnd = atom.kind { return true }
        return false
    }

    /// An original atom's place on the page: its left edge, width and line.
    private func geometry(of atom: Atom) -> (x: Double, width: Double)? {
        switch atom.kind {
        case .char(let c), .space(let c), .softHyphen(let c): return (chars[c].rect.minX, chars[c].rect.width)
        case .formula(let p): return (formulas[p].rect.minX, formulas[p].rect.width)
        case .lineEnd:
            let li = atom.line
            return (lines[li].maxX, 0)
        case .typed, .typedSpace: return nil
        }
    }

    /// Lays the paragraph out again from its first changed line, choosing where its lines break as a whole (as TeX
    /// does): each line drawn again costs, each line set looser or tighter than the page sets its words costs more the
    /// further it goes, a hyphen added costs, a line more than the page had costs a lot. The cheapest way usually keeps
    /// the edit in its own line (its spaces a little wider or narrower) and comes back to the page's own line breaks as
    /// soon as it can; from there the lines stay exactly as they are.
    private func makeLayout(shrink: Double, pitch: Double) -> Result {
        let atoms = state.atoms
        let tight = pitch < self.pitch - 0.001
        // Untouched: every line, at its place.
        guard let firstDirty = state.dirty.min(), atoms != originalAtoms else {
            return Result(lines: lines.indices.map { li in
                Line(baseline: lines[li].baseline, items: originalPlaced(li), untouched: true, original: li)
            }, rewritten: [])
        }
        var result: [Line] = []
        for li in 0..<min(firstDirty, lines.count) {
            result.append(Line(baseline: lines[li].baseline, items: originalPlaced(li), untouched: true, original: li))
        }
        let start = atoms.firstIndex { $0.line >= firstDirty } ?? atoms.count
        let pieces = self.pieces(from: start, atoms: atoms)
        let n = pieces.count
        func baseline(_ slot: Int) -> Double {
            tight ? lines[min(firstDirty, lines.count - 1)].baseline - pitch * Double(slot - firstDirty)
                : slot < lines.count ? lines[slot].baseline : lines.last!.baseline - pitch * Double(slot - lines.count + 1)
        }
        guard n > 0 else {
            // All of it deleted from here on.
            if firstDirty < lines.count, start < atoms.count || firstDirty == 0 {
                result.append(Line(baseline: baseline(firstDirty), items: [], untouched: false, original: firstDirty))
            }
            return Result(lines: result, rewritten: Set(firstDirty..<max(firstDirty, lines.count)))
        }

        // From atom i on: the page's own atoms, in their order, to the paragraph's end.
        var tail = [Bool](repeating: false, count: atoms.count + 1)
        tail[atoms.count] = true
        // From atom i on: how far the page's own atoms run on in their order.
        var run = [Int](repeating: -1, count: atoms.count + 1)
        for i in stride(from: atoms.count - 1, through: 0, by: -1) {
            guard let o = atoms[i].original else { continue }
            tail[i] = o == originalAtoms.count - (atoms.count - i) && tail[i + 1]
            run[i] = i + 1 < atoms.count && atoms[i + 1].original == o + 1 ? run[i + 1] : i
        }
        var current: [Int: Int] = [:]   // original atom → where it is now
        for (i, atom) in atoms.enumerated() { if let o = atom.original { current[o] = i } }
        let content = lines.indices.map { originalLine($0).filter { !isGlue(originalAtoms[$0]) } }
        func firstAtom(_ p: Int) -> Int { pieces[p].atoms.first ?? pieces[p].hyphen ?? start }
        func lastAtom(_ p: Int) -> Int { pieces[p].hyphen ?? pieces[p].atoms.last ?? start }
        /// The page's line `slot`, exactly: pieces p..<b are its atoms.
        func isSame(_ slot: Int, _ p: Int, _ b: Int) -> Bool {
            guard !tight, slot < lines.count, let f = content[slot].first, let l = content[slot].last,
                  let cf = current[f], let cl = current[l], firstAtom(p) == cf, lastAtom(b - 1) == cl else { return false }
            return run[cf] >= cl
        }
        /// From piece p on, the page's lines from `slot` on, as they were.
        func converges(_ p: Int, _ slot: Int) -> Bool {
            guard !tight, slot < lines.count, let f = content[slot].first, let cf = current[f] else { return false }
            return firstAtom(p) == cf && tail[cf]
        }

        var widths = [0.0], glues = [0.0], joints = [0]
        for piece in pieces {
            widths.append(widths.last! + piece.width)
            glues.append(glues.last! + piece.natural)
            joints.append(joints.last! + (piece.kind == .cjk ? 1 : 0))
        }
        func breakWidth(_ p: Int) -> Double {
            if let h = pieces[p].hyphen { return hyphenWidth(h, atoms) }
            if pieces[p].addsHyphen, let a = pieces[p].atoms.last { return style(for: a + 1, in: atoms).advance("-") }
            return 0
        }
        /// What setting pieces p..<b as the line `slot` costs (nil: they do not fit, nor would more).
        func cost(_ slot: Int, _ p: Int, _ b: Int) -> Double? {
            if isSame(slot, p, b) { return 0 }
            let last = b == n
            let available = columnRight - left(slot)
            let words = widths[b] - widths[p] + (last ? 0 : breakWidth(b - 1))
            let glue = glues[b] - glues[p + 1]
            var badness = 0.0
            if words + glue * shrink > available + 0.01 {
                guard b == p + 1 else { return nil }
                badness = 5000
            } else if justified && !last {
                // Against the spaces the page's own lines have: 60 % wider, or 30 % narrower, is as bad as
                // it gets; the joints between CJK characters stretch by a twenty-fifth of an em.
                let spaces = glue / max(naturalSpace, 0.01)
                let slack = available - words - spaces * typicalSpace
                if slack > 0 {
                    let stretch = spaces * typicalSpace * 0.6 + Double(joints[b] - joints[p + 1]) * size * 0.04
                    badness = stretch > 0 ? 100 * pow(min(slack / stretch, 5), 3) : (slack > size ? 2000 : 0)
                } else if spaces > 0 {
                    badness = 100 * pow(min(-slack / (spaces * typicalSpace * 0.3), 5), 3)
                }
            } else {
                let slack = available - words - glue
                if !justified && !last && slack > 0 {
                    // Ragged or centred lines: fuller lines first.
                    badness = 20 * pow(slack / max(available, 1), 2)
                } else if slack < 0, glue > 0 {
                    badness = 100 * pow(-slack / (glue * 0.34), 3)
                }
            }
            var penalty = 150.0
            if slot >= lines.count { penalty += 400 }
            if !last {
                if pieces[b - 1].addsHyphen { penalty += 50 } else if pieces[b - 1].hyphen != nil { penalty += 10 }
            }
            return penalty + badness
        }

        // Lines, best first: cheapest[p][k] is the least the pieces before p cost set in k lines from the first changed.
        var total = widths[n] + glues[n]
        total = max(total, 1)
        var limit = max(lines.count - firstDirty, Int(total / max(columnRight - columnLeft, 1) * 1.4) + 2) + 2
        var choice: [(slot: Int, from: Int, to: Int)] = []
        var converged: Int?
        while choice.isEmpty {
            var cheapest = Array(repeating: Array(repeating: Double.infinity, count: limit + 1), count: n + 1)
            var from = Array(repeating: Array(repeating: -1, count: limit + 1), count: n + 1)
            cheapest[0][0] = 0
            var finish: (p: Int, k: Int, cost: Double, converged: Bool)?
            for p in 0...n {
                for k in 0...limit where cheapest[p][k] < .infinity {
                    let slot = firstDirty + k, sofar = cheapest[p][k]
                    if p == n {
                        let left = slot < lines.count ? Double(lines.count - slot) * 5 : 0
                        if sofar + left < finish?.cost ?? .infinity { finish = (p, k, sofar + left, false) }
                        continue
                    }
                    if converges(p, slot) {
                        if sofar < finish?.cost ?? .infinity { finish = (p, k, sofar, true) }
                        continue
                    }
                    guard k < limit else { continue }
                    for b in (p + 1)...n {
                        guard let c = cost(slot, p, b) else { break }
                        if sofar + c < cheapest[b][k + 1] {
                            cheapest[b][k + 1] = sofar + c
                            from[b][k + 1] = p
                        }
                    }
                }
            }
            if let finish {
                var p = finish.p, k = finish.k
                while k > 0 {
                    let a = from[p][k]
                    choice.insert((firstDirty + k - 1, a, p), at: 0)
                    p = a
                    k -= 1
                }
                if finish.converged { converged = firstDirty + finish.k }
                if choice.isEmpty { break }
            } else {
                guard limit < n + 1 else { break }
                limit = n + 1
            }
        }

        var rewritten = Set<Int>()
        for (index, line) in choice.enumerated() {
            let next = index + 1 < choice.count ? firstAtom(choice[index + 1].from) : (converged != nil ? firstAtom(line.to) : atoms.count)
            if isSame(line.slot, line.from, line.to) {
                result.append(Line(baseline: baseline(line.slot), items: originalPlaced(line.slot), untouched: true, original: line.slot))
            } else {
                let items = place(pieces, line.from..<line.to, slot: line.slot, last: line.to == n, upTo: next, atoms: atoms)
                result.append(Line(baseline: baseline(line.slot), items: items, untouched: false, original: line.slot < lines.count ? line.slot : nil))
                if line.slot < lines.count { rewritten.insert(line.slot) }
            }
        }
        if let converged {
            for li in converged..<lines.count {
                result.append(Line(baseline: lines[li].baseline, items: originalPlaced(li), untouched: true, original: li))
            }
        } else {
            // Lines of the page left empty go.
            let used = (choice.last?.slot ?? firstDirty - 1) + 1
            for li in used..<max(used, lines.count) { rewritten.insert(li) }
        }
        return Result(lines: result, rewritten: rewritten)
    }

    /// Where the line `slot` starts.
    private func left(_ slot: Int) -> Double {
        slot == 0 ? lines[0].minX : (slot < lines.count ? lines[slot].minX : columnLeft)
    }

    private func isGlue(_ atom: Atom) -> Bool {
        switch atom.kind {
        case .space, .typedSpace, .lineEnd: true
        default: false
        }
    }

    /// The page's line `li` as it is drawn.
    private func originalPlaced(_ li: Int) -> [Placed] {
        // Indices into the current row of the line's atoms (they are unchanged there).
        let ids = Set(originalLine(li))
        return state.atoms.indices.compactMap { i -> Placed? in
            guard let o = state.atoms[i].original, ids.contains(o), let g = geometry(of: state.atoms[i]) else { return nil }
            let visible: Bool
            switch state.atoms[i].kind {
            case .space, .lineEnd: visible = false
            default: visible = true
            }
            return Placed(atom: i, x: g.x, width: g.width, visible: visible)
        }
    }

    /// How far atom `i` reaches from its start to where `j` (the next atom) starts: as on the page when the two stood so
    /// there, else its advance.
    private func advance(_ atoms: [Atom], _ i: Int) -> Double {
        let atom = atoms[i]
        if i + 1 < atoms.count, let a = atom.original, let b = atoms[i + 1].original, b == a + 1,
           originalAtoms[a].line == originalAtoms[b].line, let ga = geometry(of: atom), let gb = geometry(of: atoms[i + 1]) {
            return gb.x - ga.x
        }
        return width(atoms, i)
    }

    /// The atom's own width.
    func width(_ atoms: [Atom], _ i: Int) -> Double {
        switch atoms[i].kind {
        case .typed(let s): return style(for: i, in: atoms).advance(s)
        case .typedSpace, .space, .lineEnd: return 0
        default: return geometry(of: atoms[i])?.width ?? 0
        }
    }

    /// A word, or a part of one where the line may break (after a soft hyphen of the page, a hyphen of its own, a place
    /// the hyphenation dictionary allows), or a CJK character; and the glue before it.
    struct Piece {
        enum Kind { case word, cjk, part }
        var atoms: [Int]
        var width: Double
        /// The glue atom that takes the gap's width.
        var glueBefore: Int?
        /// The gap's natural width.
        var natural: Double
        /// A soft hyphen of the page ending it: drawn when the line breaks here.
        var hyphen: Int?
        /// A place the dictionary allows: a hyphen is drawn when the line breaks here.
        var addsHyphen = false
        var kind: Kind = .word
    }

    /// The pieces of the atoms from `start` to the paragraph's end.
    private func pieces(from start: Int, atoms: [Atom]) -> [Piece] {
        var pieces: [Piece] = []
        var i = start
        var pendingGlue: Int?
        var pendingNatural = 0.0
        var afterSoftHyphen = false
        while i < atoms.count {
            let atom = atoms[i]
            if isGlue(atom) {
                if pendingGlue == nil || pendingNatural == 0 {
                    pendingGlue = i
                    if case .lineEnd(let spaced) = atom.kind { pendingNatural = spaced ? naturalSpace : 0 } else { pendingNatural = naturalSpace }
                }
                afterSoftHyphen = false
                i += 1
                continue
            }
            // A word: up to glue, a soft hyphen, or a CJK character.
            var word: [Int] = [], hyphen: Int?
            var k = i
            var cjk = false
            while k < atoms.count, !isGlue(atoms[k]) {
                if case .softHyphen = atoms[k].kind {
                    hyphen = k
                    k += 1
                    break
                }
                let t = text(of: atoms[k])
                let isCJK = Self.isCJK(t.unicodeScalars.first)
                // A line may break before or after a CJK character, but not before closing punctuation nor after
                // opening punctuation.
                if let previous = word.last.map({ text(of: atoms[$0]) }), isCJK || Self.isCJK(previous.unicodeScalars.last),
                   !Self.closing.contains(t), !Self.opening.contains(previous) {
                    break
                }
                word.append(k)
                k += 1
                if isCJK { cjk = true }
            }
            let joined = pendingGlue == nil && !pieces.isEmpty
            let kind: Piece.Kind = afterSoftHyphen ? .part : (joined && (cjk || pieces.last.map { lastIsCJK($0, atoms) } == true) ? .cjk : (joined ? .cjk : .word))
            let natural = pieces.isEmpty || pendingGlue == nil ? 0 : pendingNatural
            // Where else the word may break.
            let cuts = cjk ? [] : breaks(in: word, atoms: atoms)
            var bounds = [0] + cuts + [word.count]
            bounds = Array(Set(bounds)).sorted()
            for (m, (a, b)) in zip(bounds, bounds.dropFirst()).enumerated() {
                let part = Array(word[a..<b])
                var w = 0.0
                for x in part { w += x + 1 < atoms.count && !isGlue(atoms[x + 1]) ? advance(atoms, x) : width(atoms, x) }
                let isLast = b == word.count
                var piece = Piece(atoms: part, width: w, glueBefore: m == 0 ? pendingGlue : nil, natural: m == 0 ? natural : 0,
                                  hyphen: isLast ? hyphen : nil, kind: m == 0 ? kind : .part)
                // A break after a hyphen of the word adds none.
                if !isLast, let lastAtom = part.last, !["-", "\u{2010}"].contains(text(of: atoms[lastAtom])) { piece.addsHyphen = true }
                pieces.append(piece)
            }
            if word.isEmpty, let hyphen {
                pieces.append(Piece(atoms: [], width: 0, glueBefore: pendingGlue, natural: natural, hyphen: hyphen, kind: kind))
            }
            afterSoftHyphen = hyphen != nil
            pendingGlue = nil
            pendingNatural = 0
            i = k
        }
        return pieces
    }

    /// Punctuation a line never starts with, and punctuation it never ends with.
    static let closing: Set<String> = ["，", "。", "、", "；", "：", "？", "！", "）", "」", "』", "】", "〕", "〉", "》", "”", "’", "…", "·", "％",
                                       ",", ".", ";", ":", "?", "!", ")", "]", "}", "%", "'", "\u{201D}"]
    static let opening: Set<String> = ["（", "「", "『", "【", "〔", "〈", "《", "“", "‘", "(", "[", "{", "\u{201C}"]

    private func lastIsCJK(_ piece: Piece, _ atoms: [Atom]) -> Bool {
        guard let a = piece.atoms.last else { return false }
        return Self.isCJK(text(of: atoms[a]).unicodeScalars.last)
    }

    private var hyphenationCache: [String: [Int]] = [:]

    /// Where a word may break besides its glue: after a hyphen of its own between letters ("learning-|based"), and in a
    /// run of five Latin letters or more where the system's hyphenation dictionary allows (two letters before, three after).
    private func breaks(in word: [Int], atoms: [Atom]) -> [Int] {
        guard word.count >= 4 else { return [] }
        let texts = word.map { text(of: atoms[$0]) }
        func isLetter(_ n: Int) -> Bool {
            n >= 0 && n < texts.count && texts[n].count == 1 && texts[n].first!.isLetter
                && texts[n].unicodeScalars.allSatisfy { $0.value < 0x0250 }
        }
        var cuts: [Int] = []
        for at in 2..<word.count where ["-", "\u{2010}"].contains(texts[at - 1]) && isLetter(at - 2) && isLetter(at) { cuts.append(at) }
        // Runs of letters.
        var n = 0
        while n < word.count {
            guard isLetter(n) else { n += 1; continue }
            var end = n
            while end < word.count, isLetter(end) { end += 1 }
            if end - n >= 5 {
                let run = texts[n..<end].joined()
                let points: [Int]
                if let cached = hyphenationCache[run] {
                    points = cached
                } else {
                    points = Self.hyphenationPoints(run)
                    hyphenationCache[run] = points
                }
                cuts += points.map { $0 + n }
            }
            n = end
        }
        return cuts
    }

    /// The dictionary's hyphenation places in a word of Latin letters, two letters before and three after at least.
    static func hyphenationPoints(_ word: String) -> [Int] {
        let string = word as NSString
        let locale = Locale(identifier: "en_US") as CFLocale
        guard string.length == word.count, CFStringIsHyphenationAvailableForLocale(locale) else { return [] }
        var points: [Int] = []
        var limit = string.length - 3
        while limit >= 2 {
            let at = CFStringGetHyphenationLocationBeforeIndex(string, limit + 1, CFRange(location: 0, length: string.length), 0, locale, nil)
            guard at != kCFNotFound, at >= 2, at <= limit else { break }
            points.append(at)
            limit = at - 1
        }
        return points.reversed()
    }

    /// The items of the line `slot` set from pieces `range`, and the glue after it up to `next` (where the next line
    /// starts).
    private func place(_ pieces: [Piece], _ range: Range<Int>, slot: Int, last: Bool, upTo next: Int, atoms: [Atom]) -> [Placed] {
        let left = left(slot)
        let right = columnRight
        let available = right - left
        let line = Array(pieces[range])
        guard let end = line.last else { return [] }
        let breaksAtHyphen = !last && end.hyphen != nil
        let addsHyphen = !last && end.addsHyphen && end.hyphen == nil
        let hyphenAdvance = addsHyphen ? style(for: (end.atoms.last ?? 0) + 1, in: atoms).advance("-") : 0
        let natural = line.enumerated().reduce(0.0) { $0 + ($1.offset == 0 ? 0 : $1.element.natural) + $1.element.width }
            + (breaksAtHyphen ? hyphenWidth(end.hyphen!, atoms) : 0) + hyphenAdvance
        // Spaces take the slack (CJK characters when there are none; never the inside of a word).
        let gaps = line.dropFirst()
        var extra = 0.0
        if justified && !last || natural > available + 0.01 { extra = available - natural }
        // Stretching, spaces and the joints between CJK characters share it as they can; squeezing, spaces alone.
        var weight: [Double] = gaps.map { $0.natural > 0 ? $0.natural * 0.6 : ($0.kind == .cjk && extra > 0 ? size * 0.1 : 0) }
        if weight.allSatisfy({ $0 == 0 }) { weight = gaps.map { $0.kind == .cjk ? 1 : 0 } }
        let weightSum = weight.reduce(0, +)
        if weightSum == 0 { extra = 0 }
        var x = left
        if centered { x = columnLeft + (right - columnLeft - natural) / 2 }
        var items: [Placed] = []
        var previousEnd: Int?
        for (n, piece) in line.enumerated() {
            let first = piece.atoms.first ?? piece.hyphen ?? 0
            if n > 0 {
                let gap = piece.natural + (weightSum > 0 ? extra * weight[n - 1] / weightSum : 0)
                // The glue between the pieces: the one taking the gap, the others with none.
                if let p = previousEnd, p + 1 < first {
                    for g in (p + 1)..<first {
                        items.append(Placed(atom: g, x: x, width: g == piece.glueBefore ? max(gap, 0) : 0, visible: false))
                    }
                }
                x += gap
            }
            for (m, a) in piece.atoms.enumerated() {
                let w = m + 1 < piece.atoms.count ? advance(atoms, a) : width(atoms, a)
                let advanceToNext = m + 1 < piece.atoms.count ? w : (a + 1 < atoms.count && !isGlue(atoms[a + 1]) ? advance(atoms, a) : w)
                items.append(Placed(atom: a, x: x, width: width(atoms, a), visible: true,
                                    hyphenAfter: addsHyphen && n == line.count - 1 && m == piece.atoms.count - 1))
                x += m + 1 < piece.atoms.count ? w : advanceToNext
            }
            if let h = piece.hyphen {
                let shown = breaksAtHyphen && n == line.count - 1
                items.append(Placed(atom: h, x: x, width: shown ? hyphenWidth(h, atoms) : 0, visible: shown))
                if shown { x += hyphenWidth(h, atoms) }
            }
            previousEnd = piece.hyphen ?? piece.atoms.last ?? previousEnd
        }
        if addsHyphen { x += hyphenAdvance }
        // The glue at the break belongs to this line (the caret can stand after it at the line's end).
        if let p = previousEnd, p + 1 < next {
            for g in (p + 1)..<next { items.append(Placed(atom: g, x: x, width: 0, visible: false)) }
        }
        return items
    }

    private func hyphenWidth(_ i: Int, _ atoms: [Atom]) -> Double {
        if case .softHyphen(let c) = atoms[i].kind { return chars[c].rect.width }
        return 0
    }

    // MARK: Typed characters

    /// How a typed character is drawn: the glyph it borrows (font, code, width) or the system font standing in, at the
    /// size, slant, colour and height of the text beside it.
    struct Style {
        var context: Glyph
        /// Rise of the context above its line's baseline.
        var rise: Double
        let paragraph: PDFParagraph

        /// A glyph of the page for `text` in the context's font (or one like it), as drawn at the context's size.
        func glyph(_ text: String) -> Glyph? {
            paragraph.borrow(text, like: context)
        }

        func advance(_ text: String) -> Double {
            if let g = glyph(text) { return g.width * hypot(context.matrix.a, context.matrix.b) }
            return paragraph.fallbackFont(like: context).map { font in
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
                return CTLineGetTypographicBounds(line, nil, nil, nil)
            } ?? context.size * 0.5
        }
    }

    /// The style of the typed atom `i`: from the nearest drawn character before it, else after it.
    func style(for i: Int, in atoms: [Atom]) -> Style {
        func contextGlyph(_ k: Int) -> (Glyph, Double)? {
            switch atoms[k].kind {
            case .char(let c), .softHyphen(let c):
                guard let g = chars[c].glyphs.first, g < interpreter.glyphs.count else { return nil }
                let glyph = interpreter.glyphs[g]
                return (glyph, glyph.origin.y - lines[charLine[c]].baseline)
            default: return nil
            }
        }
        for k in stride(from: i - 1, through: 0, by: -1) {
            if let (g, rise) = contextGlyph(k) { return Style(context: g, rise: rise, paragraph: self) }
        }
        for k in (i + 1)..<max(i + 1, atoms.count) {
            if let (g, rise) = contextGlyph(k) { return Style(context: g, rise: rise, paragraph: self) }
        }
        // Nothing to go by (all of it typed anew): the paragraph's first glyph.
        let first = chars.first { !$0.glyphs.isEmpty }.flatMap { $0.glyphs.first }.map { interpreter.glyphs[$0] }
        let g = first ?? Glyph(run: -1, code: 0, length: 1, font: -1, matrix: CGAffineTransform(scaleX: size, y: size), width: 0.5, size: size,
                              text: nil, reliable: false, renderMode: 0, color: .black, element: 0, offset: 0, adjustment: nil, depth: nil)
        return Style(context: g, rise: 0, paragraph: self)
    }

    /// A glyph drawing `text` in `context`'s font (else a font of the page in the same style), sized and placed like it.
    func borrow(_ text: String, like context: Glyph) -> Glyph? {
        func make(font: Int, code: Int, length: Int, width: Double) -> Glyph {
            var g = context
            g.font = font
            g.code = code
            g.length = length
            g.width = width
            g.text = text
            g.reliable = true
            g.run = -1
            return g
        }
        guard context.font >= 0 else { return nil }
        if let d = donors[context.font]?[text] {
            let donor = interpreter.glyphs[d]
            return make(font: context.font, code: donor.code, length: donor.length, width: donor.width)
        }
        // A whole font (not a subset): any character its tables name.
        let metrics = interpreter.fonts[context.font]
        if !Self.isSubset(metrics.dict), let code = metrics.encoding.code(for: text) {
            let composite = PDFDictionary.name(metrics.dict, "Subtype") == "Type0"
            return make(font: context.font, code: code, length: composite ? 2 : 1, width: metrics.width(code))
        }
        // Another font of the page in the same style that has it.
        let info = metrics.info
        for (font, glyphs) in donors where font != context.font {
            let other = interpreter.fonts[font].info
            guard other.isBold == info.isBold, other.isItalic == info.isItalic, other.isSerif == info.isSerif, other.isMonospace == info.isMonospace,
                  let d = glyphs[text] else { continue }
            let donor = interpreter.glyphs[d]
            return make(font: font, code: donor.code, length: donor.length, width: donor.width)
        }
        return nil
    }

    static func isSubset(_ dict: CGPDFDictionaryRef) -> Bool {
        guard let name = PDFDictionary.name(dict, "BaseFont") else { return true }
        return name.range(of: #"^[A-Z]{6}\+"#, options: .regularExpression) != nil
    }

    /// The system font standing in for a character no font of the page has: the context's size, weight, slant and
    /// family kind (serif or sans; Songti or PingFang for CJK).
    func fallbackFont(like context: Glyph) -> CTFont? {
        let info = context.font >= 0 ? interpreter.fonts[context.font].info : FontInfo.unknown
        let size = hypot(context.matrix.c, context.matrix.d)
        let name = info.isSerif ? "Times New Roman" : "Helvetica Neue"
        var font = CTFontCreateWithName(name as CFString, max(size, 1), nil)
        var traits: CTFontSymbolicTraits = []
        if info.isBold { traits.insert(.boldTrait) }
        if info.isItalic { traits.insert(.italicTrait) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) { font = styled }
        return font
    }

    // MARK: Drawing

    /// What the edited lines draw: glyphs of the page (moved, or borrowed for typed characters), formulas moved whole,
    /// characters in a system font, and the page's lines they replace.
    struct Drawing {
        var glyphs: [Glyph] = []
        var transplants: [Transplant] = []
        /// Formulas that stay where they are (in a line that is drawn again).
        var stayingFormulas: Set<Int> = []
        var fallback: [(text: String, origin: CGPoint, font: CTFont, color: RGBColor)] = []
        var rewritten: Set<Int> = []
        /// Where the links of the edited lines go.
        var linkPlaces: [Int: [CGRect]] = [:]
    }

    func drawing() -> Drawing {
        let result = layout
        let atoms = state.atoms
        var drawing = Drawing(rewritten: result.rewritten)
        var linkRects: [Int: [CGRect]] = [:]
        for line in result.lines where !line.untouched {
            for item in line.items where item.visible {
                let atom = atoms[item.atom]
                switch atom.kind {
                case .char(let c), .softHyphen(let c):
                    let dx = item.x - chars[c].rect.minX, dy = line.baseline - lines[charLine[c]].baseline
                    for g in chars[c].glyphs where g < interpreter.glyphs.count {
                        var glyph = interpreter.glyphs[g]
                        glyph.matrix = glyph.matrix.concatenating(CGAffineTransform(translationX: dx, y: dy))
                        drawing.glyphs.append(glyph)
                    }
                    if let link = chars[c].link {
                        linkRects[link, default: []].append(chars[c].rect.offsetBy(dx: dx, dy: dy))
                    }
                    if item.hyphenAfter { appendHyphen(after: item, baseline: line.baseline, atoms: atoms, to: &drawing) }
                case .formula(let p):
                    let span = formulas[p]
                    let dx = item.x - span.rect.minX, dy = line.baseline - span.baseline
                    // Moved or not, a formula of a line drawn again is drawn again whole (with its bars and pictures).
                    drawing.transplants.append(Transplant(formula: span, origin: CGPoint(x: item.x, y: line.baseline), scale: 1))
                    for link in span.links { linkRects[link.link, default: []].append(link.rect.offsetBy(dx: dx, dy: dy)) }
                case .typed(let s):
                    let style = style(for: item.atom, in: atoms)
                    let origin = CGPoint(x: item.x, y: line.baseline + style.rise)
                    if var glyph = style.glyph(s) {
                        glyph.matrix.tx = origin.x
                        glyph.matrix.ty = origin.y
                        drawing.glyphs.append(glyph)
                    } else if let font = fallbackFont(like: style.context) {
                        drawing.fallback.append((s, origin, font, style.context.color))
                    }
                    if item.hyphenAfter { appendHyphen(after: item, baseline: line.baseline, atoms: atoms, to: &drawing) }
                default: break
                }
            }
        }
        // Links of the edited lines: where their words went, and where they stay in the lines left alone.
        for li in result.rewritten where li < lines.count {
            for c in lines[li].chars { if let link = c.link, linkRects[link] == nil { linkRects[link] = [] } }
        }
        for (link, _) in linkRects {
            for line in result.lines where line.untouched {
                guard let li = line.original else { continue }
                for c in lines[li].chars where c.link == link { linkRects[link]!.append(c.rect) }
            }
        }
        drawing.linkPlaces = linkRects.mapValues(Self.mergedRects)
        return drawing
    }

    /// The hyphen of a word broken by hyphenation, in the word's font, right after its last letter.
    private func appendHyphen(after item: Placed, baseline: Double, atoms: [Atom], to drawing: inout Drawing) {
        let style = style(for: item.atom + 1, in: atoms)
        let origin = CGPoint(x: item.x + item.width, y: baseline + style.rise)
        if var glyph = style.glyph("-") ?? style.glyph("\u{2010}") {
            glyph.matrix.tx = origin.x
            glyph.matrix.ty = origin.y
            drawing.glyphs.append(glyph)
        } else if let font = fallbackFont(like: style.context) {
            drawing.fallback.append(("-", origin, font, style.context.color))
        }
    }

    /// Rectangles of one line merged (a link over several words is one place per line).
    static func mergedRects(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for r in rects.sorted(by: { $0.minY != $1.minY ? $0.minY > $1.minY : $0.minX < $1.minX }) {
            if let last = result.last, abs(last.midY - r.midY) < r.height * 0.5, r.minX - last.maxX < r.height {
                result[result.count - 1] = last.union(r)
            } else {
                result.append(r)
            }
        }
        return result
    }

    /// Content drawing `glyphs` with their fonts (named by `fontName`).
    static func content(_ glyphs: [Glyph], fontName: (Int) -> String) -> String {
        guard !glyphs.isEmpty else { return "" }
        var out = "BT 0 Tc 0 Tw 100 Tz 0 Ts\n"
        var font = -1, mode = -1
        var color: RGBColor?
        for g in glyphs where g.font >= 0 {
            if g.font != font {
                font = g.font
                out += "/\(fontName(font)) 1 Tf\n"
            }
            if g.color != color {
                color = g.color
                let c = "\(PDFValue.format(g.color.r)) \(PDFValue.format(g.color.g)) \(PDFValue.format(g.color.b))"
                out += "\(c) rg \(c) RG\n"
            }
            let render = min(g.renderMode, 2)
            if render != mode {
                mode = render
                out += "\(render) Tr\n"
            }
            var code = ""
            for k in stride(from: g.length - 1, through: 0, by: -1) { code += String(format: "%02X", (g.code >> (8 * k)) & 0xFF) }
            let m = g.matrix
            out += [m.a, m.b, m.c, m.d, m.tx, m.ty].map { PDFValue.format(Double($0)) }.joined(separator: " ") + " Tm <\(code)> Tj\n"
        }
        return out + "ET\n"
    }

    // MARK: For the editor's view (page space)

    /// The lines as they are now (for the caret, the selection and hit testing).
    public struct ShownLine: Sendable {
        public var baseline: Double
        /// Caret positions: before each atom of the line (atom index, x), and after its last.
        public var stops: [(index: Int, x: Double)]
        public var top: Double
        public var bottom: Double
    }

    public var shownLines: [ShownLine] {
        let result = layout
        var shown: [ShownLine] = []
        for line in result.lines {
            var stops: [(Int, Double)] = []
            for item in line.items { stops.append((item.atom, item.x)) }
            if let last = line.items.last { stops.append((last.atom + 1, last.x + last.width)) }
            shown.append(ShownLine(baseline: line.baseline, stops: stops, top: line.baseline + size * 0.92, bottom: line.baseline - size * 0.28))
        }
        if shown.isEmpty {
            let left = lines.first?.minX ?? columnLeft
            let baseline = lines.first?.baseline ?? 0
            shown = [ShownLine(baseline: baseline, stops: [(0, left)], top: baseline + size * 0.92, bottom: baseline - size * 0.28)]
        }
        return shown
    }

    /// The area the paragraph covers now (page space).
    public var bounds: CGRect {
        let shown = shownLines
        let top = shown.map(\.top).max() ?? 0, bottom = shown.map(\.bottom).min() ?? 0
        return CGRect(x: columnLeft, y: bottom, width: columnRight - columnLeft, height: top - bottom).union(lines.first.map { CGRect(x: $0.minX, y: bottom, width: 1, height: 1) } ?? .null)
    }

    /// What to paint over the page while editing: white over the lines drawn again, and the page's glyphs in their new
    /// places as a one-page PDF in page space (nil when nothing changed). `fallback` is drawn with Core Text.
    public struct Preview: @unchecked Sendable {
        public var cover: [CGRect]
        public var page: CGPDFPage?
        public var document: CGPDFDocument?
        public var fallback: [(text: String, origin: CGPoint, font: CTFont, color: CGColor)]

        public init(cover: [CGRect], page: CGPDFPage?, document: CGPDFDocument?, fallback: [(text: String, origin: CGPoint, font: CTFont, color: CGColor)]) {
            self.cover = cover
            self.page = page
            self.document = document
            self.fallback = fallback
        }
    }

    public func preview() -> Preview {
        let drawing = drawing()
        guard !drawing.rewritten.isEmpty || !drawing.glyphs.isEmpty else { return Preview(cover: [], page: nil, document: nil, fallback: []) }
        var cover: [CGRect] = []
        for li in drawing.rewritten where li < lines.count {
            let line = lines[li]
            for c in line.chars where !c.isSpace && !c.glyphs.isEmpty {
                // Formulas staying put are not covered.
                if let p = formulas.firstIndex(where: { Set($0.glyphs).isSuperset(of: c.glyphs) }), drawing.stayingFormulas.contains(p) { continue }
                let box = c.glyphs.compactMap { $0 < interpreter.glyphs.count ? interpreter.glyphs[$0].box : nil }.reduce(c.rect) { $0.union($1) }
                cover.append(box.insetBy(dx: -0.4, dy: -0.4))
            }
            for p in formulas.indices where !drawing.stayingFormulas.contains(p) && abs(formulas[p].baseline - line.baseline) < line.size {
                let f = formulas[p]
                cover.append((f.ink.isNull ? f.rect : f.rect.union(f.ink)).insetBy(dx: -0.5, dy: -0.5))
            }
        }
        let writer = PDFWriter()
        let copier = PDFCopier(writer: writer)
        var fonts: [String: PDFValue] = [:]
        var fontNames: [Int: String] = [:]
        var content = PDFParagraph.content(drawing.glyphs) { font in
            if let name = fontNames[font] { return name }
            let name = "P\(fontNames.count)"
            fontNames[font] = name
            fonts[name] = copier.copy(dictionary: interpreter.fonts[font].dict)
            return name
        }
        var xobjects: [String: Int] = [:]
        let formulaDrawing = TranslationRenderer.formulaContent(drawing.transplants, orphans: [], droppedRules: [], chips: [:], interpreter: interpreter,
                                                                copier: copier, prefix: "PF", xobjects: &xobjects, fonts: &fonts)
        content += formulaDrawing.content
        var resources: [String: PDFValue] = ["Font": .dict(fonts)]
        if !xobjects.isEmpty { resources["XObject"] = .dict(xobjects.mapValues { .ref($0) }) }
        let pages = writer.reserve()
        let pageObject = writer.add(.dict(["Type": .name("Page"), "Parent": .ref(pages), "MediaBox": .rect(mediaBox),
                                           "Resources": .dict(resources), "Contents": .ref(writer.addStream(dict: [:], data: Data(content.utf8)))]))
        writer.set(pages, .dict(["Type": .name("Pages"), "Kids": .array([.ref(pageObject)]), "Count": .int(1)]))
        let root = writer.add(.dict(["Type": .name("Catalog"), "Pages": .ref(pages)]))
        let data = writer.finish(root: root, info: nil)
        let document = CGDataProvider(data: data as CFData).flatMap { CGPDFDocument($0) }
        let fallback = drawing.fallback.map { ($0.text, $0.origin, $0.font, CGColor(red: $0.color.r, green: $0.color.g, blue: $0.color.b, alpha: 1)) }
        return Preview(cover: cover, page: document?.page(at: 1), document: document, fallback: fallback)
    }
}
