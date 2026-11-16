import CoreGraphics
import Foundation

/// A colour space as far as the engine needs one: to know what colour the numbers a page paints with show
/// (PDF 32000-1 §8.6). `1 scn` is black in a Separation "Black" space and white in a gray one; reading every colour
/// as gray, RGB or CMYK by its number of components drew translations in white.
indirect enum PDFColorSpace: Sendable {
    case gray, rgb, cmyk, lab
    case indexed(base: PDFColorSpace, high: Int, table: [UInt8])
    /// Separation and DeviceN: tints, through the space's function, into its alternate space.
    case tint(names: [String], alternate: PDFColorSpace, function: PDFFunction?)
    /// Pattern: coloured patterns carry no numbers; uncoloured ones paint with their base space's.
    case pattern(base: PDFColorSpace?)

    var components: Int {
        switch self {
        case .gray, .indexed: 1
        case .rgb, .lab: 3
        case .cmyk: 4
        case .tint(let names, _, _): max(names.count, 1)
        case .pattern(let base): base?.components ?? 0
        }
    }

    /// The colour a space starts with when it is chosen (`cs`).
    var initial: [Double] {
        switch self {
        case .gray, .indexed: [0]
        case .rgb, .lab: [0, 0, 0]
        case .cmyk: [0, 0, 0, 1]
        case .tint(let names, _, _): Array(repeating: 1, count: max(names.count, 1))
        case .pattern: []
        }
    }

    /// The colour the numbers show, in RGB.
    func rgb(_ n: [Double]) -> RGBColor {
        func at(_ i: Int, _ fallback: Double = 0) -> Double { i < n.count ? n[i] : fallback }
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        switch self {
        case .gray:
            let v = clamp(at(0))
            return RGBColor(r: v, g: v, b: v)
        case .rgb:
            return RGBColor(r: clamp(at(0)), g: clamp(at(1)), b: clamp(at(2)))
        case .cmyk:
            let c = clamp(at(0)), m = clamp(at(1)), y = clamp(at(2)), k = clamp(at(3, 1))
            return RGBColor(r: (1 - c) * (1 - k), g: (1 - m) * (1 - k), b: (1 - y) * (1 - k))
        case .lab:
            return Self.labToRGB(l: at(0), a: at(1), b: at(2))
        case .indexed(let base, let high, let table):
            let index = min(max(Int(at(0).rounded()), 0), high)
            let count = base.components
            guard count > 0, (index + 1) * count <= table.count else { return .black }
            let values = (0..<count).map { Double(table[index * count + $0]) / 255 }
            // Lab tables hold L* 0…100 and a*, b* −128…127 in bytes.
            if case .lab = base {
                return base.rgb([values[0] * 100, values[1] * 255 - 128, values[2] * 255 - 128])
            }
            return base.rgb(values)
        case .tint(let names, let alternate, let function):
            let tints = n.isEmpty ? initial : n
            if names.count == 1, names[0] == "None" { return RGBColor(r: 1, g: 1, b: 1) }
            if let function {
                let out = function.evaluate(tints)
                if out.count >= alternate.components, alternate.components > 0 { return alternate.rgb(out) }
            }
            // No function to follow: the more ink, the darker (right for Black and All, close enough for a spot colour).
            let ink = clamp(tints.max() ?? 1)
            return RGBColor(r: 1 - ink, g: 1 - ink, b: 1 - ink)
        case .pattern(let base):
            guard let base, !n.isEmpty else { return .black }
            return base.rgb(n)
        }
    }

    /// The space a `cs` operand names: a device space, or one in the resources' ColorSpace dictionary.
    static func named(_ name: String, resources: CGPDFDictionaryRef?) -> PDFColorSpace {
        if let device = device(name) { return device }
        if let resources, let spaces = PDFDictionary.dict(resources, "ColorSpace"),
           let object = PDFDictionary.object(spaces, name), let space = parse(object, depth: 0) {
            return space
        }
        return .gray
    }

    private static func device(_ name: String) -> PDFColorSpace? {
        switch name {
        case "DeviceGray", "G", "CalGray": .gray
        case "DeviceRGB", "RGB", "CalRGB": .rgb
        case "DeviceCMYK", "CMYK": .cmyk
        case "Pattern": .pattern(base: nil)
        default: nil
        }
    }

    static func parse(_ object: CGPDFObjectRef, depth: Int) -> PDFColorSpace? {
        guard depth < 6 else { return nil }
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &name), let name { return device(String(cString: name)) }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetCount(array) > 0 else { return nil }
        var family: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 0, &family), let family else { return nil }
        func element(_ i: Int) -> CGPDFObjectRef? {
            var value: CGPDFObjectRef?
            return CGPDFArrayGetObject(array, i, &value) ? value : nil
        }
        switch String(cString: family) {
        case "CalGray": return .gray
        case "CalRGB": return .rgb
        case "Lab": return .lab
        case "ICCBased":
            var stream: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, 1, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return .rgb }
            if let alternate = PDFDictionary.object(dict, "Alternate"), let space = parse(alternate, depth: depth + 1) { return space }
            switch Int(PDFDictionary.number(dict, "N") ?? 3) {
            case 1: return .gray
            case 4: return .cmyk
            default: return .rgb
            }
        case "Indexed", "I":
            guard let baseObject = element(1), let base = parse(baseObject, depth: depth + 1) else { return nil }
            var high: CGPDFInteger = 0
            CGPDFArrayGetInteger(array, 2, &high)
            var table: [UInt8] = []
            var string: CGPDFStringRef?
            var stream: CGPDFStreamRef?
            if CGPDFArrayGetString(array, 3, &string), let string, let bytes = CGPDFStringGetBytePtr(string) {
                table = Array(UnsafeBufferPointer(start: bytes, count: CGPDFStringGetLength(string)))
            } else if CGPDFArrayGetStream(array, 3, &stream), let stream {
                table = [UInt8](ContentInterpreter.data(of: stream))
            }
            return .indexed(base: base, high: Int(high), table: table)
        case "Separation":
            var colorant: UnsafePointer<CChar>?
            CGPDFArrayGetName(array, 1, &colorant)
            let alternate = element(2).flatMap { parse($0, depth: depth + 1) } ?? .gray
            return .tint(names: [colorant.map { String(cString: $0) } ?? ""], alternate: alternate,
                         function: element(3).flatMap { PDFFunction.parse($0, depth: 0) })
        case "DeviceN":
            var namesArray: CGPDFArrayRef?
            var names: [String] = []
            if CGPDFArrayGetArray(array, 1, &namesArray), let namesArray {
                for i in 0..<CGPDFArrayGetCount(namesArray) {
                    var n: UnsafePointer<CChar>?
                    names.append(CGPDFArrayGetName(namesArray, i, &n) && n != nil ? String(cString: n!) : "")
                }
            }
            let alternate = element(2).flatMap { parse($0, depth: depth + 1) } ?? .gray
            return .tint(names: names, alternate: alternate, function: element(3).flatMap { PDFFunction.parse($0, depth: 0) })
        case "Pattern":
            return .pattern(base: element(1).flatMap { parse($0, depth: depth + 1) })
        default:
            return device(String(cString: family))
        }
    }

    /// CIE L*a*b* (D50) to sRGB, near enough to tell dark from light.
    private static func labToRGB(l: Double, a: Double, b: Double) -> RGBColor {
        let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func f(_ t: Double) -> Double { t * t * t > 0.008856 ? t * t * t : (t - 16.0 / 116) / 7.787 }
        let x = 0.9642 * f(fx), y = 1.0 * f(fy), z = 0.8249 * f(fz)
        let r = 3.1339 * x - 1.6169 * y - 0.4906 * z
        let g = -0.9788 * x + 1.9161 * y + 0.0335 * z
        let bl = 0.0719 * x - 0.2290 * y + 1.4052 * z
        func gamma(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return RGBColor(r: gamma(r), g: gamma(g), b: gamma(bl))
    }
}

/// A PDF function (§7.10): sampled, exponential, stitching or PostScript calculator, as a Separation or DeviceN space
/// turns its tints into its alternate colour.
indirect enum PDFFunction: Sendable {
    case sampled(domain: [Double], range: [Double], size: [Int], bits: Int, encode: [Double], decode: [Double], samples: [UInt8])
    case exponential(domain: [Double], c0: [Double], c1: [Double], n: Double)
    case stitching(domain: [Double], functions: [PDFFunction], bounds: [Double], encode: [Double])
    case calculator(domain: [Double], range: [Double], program: [PostScriptCalculator.Token])
    case array([PDFFunction])

    static func parse(_ object: CGPDFObjectRef, depth: Int) -> PDFFunction? {
        guard depth < 6 else { return nil }
        var array: CGPDFArrayRef?
        if CGPDFObjectGetValue(object, .array, &array), let array {
            let parts = (0..<CGPDFArrayGetCount(array)).compactMap { i -> PDFFunction? in
                var value: CGPDFObjectRef?
                return CGPDFArrayGetObject(array, i, &value) ? value.flatMap { parse($0, depth: depth + 1) } : nil
            }
            return parts.isEmpty ? nil : .array(parts)
        }
        var dict: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        if CGPDFObjectGetValue(object, .stream, &stream), let stream { dict = CGPDFStreamGetDictionary(stream) }
        else { CGPDFObjectGetValue(object, .dictionary, &dict) }
        guard let dict else { return nil }
        func numbers(_ key: String) -> [Double] { PDFDictionary.array(dict, key).map(PDFDictionary.numbers) ?? [] }
        let domain = numbers("Domain")
        switch Int(PDFDictionary.number(dict, "FunctionType") ?? -1) {
        case 0:
            guard let stream else { return nil }
            let size = numbers("Size").map { max(Int($0), 1) }
            let range = numbers("Range")
            guard !size.isEmpty, range.count >= 2 else { return nil }
            let encode = numbers("Encode")
            let decode = numbers("Decode")
            return .sampled(domain: domain, range: range, size: size, bits: Int(PDFDictionary.number(dict, "BitsPerSample") ?? 8),
                            encode: encode.isEmpty ? size.flatMap { [0, Double($0 - 1)] } : encode,
                            decode: decode.isEmpty ? range : decode, samples: [UInt8](ContentInterpreter.data(of: stream)))
        case 2:
            let c0 = numbers("C0"), c1 = numbers("C1")
            return .exponential(domain: domain, c0: c0.isEmpty ? [0] : c0, c1: c1.isEmpty ? [1] : c1, n: PDFDictionary.number(dict, "N") ?? 1)
        case 3:
            guard let list = PDFDictionary.array(dict, "Functions") else { return nil }
            let functions = (0..<CGPDFArrayGetCount(list)).compactMap { i -> PDFFunction? in
                var value: CGPDFObjectRef?
                return CGPDFArrayGetObject(list, i, &value) ? value.flatMap { parse($0, depth: depth + 1) } : nil
            }
            guard functions.count == CGPDFArrayGetCount(list), !functions.isEmpty else { return nil }
            return .stitching(domain: domain, functions: functions, bounds: numbers("Bounds"), encode: numbers("Encode"))
        case 4:
            guard let stream, let program = PostScriptCalculator.parse(ContentInterpreter.data(of: stream)) else { return nil }
            return .calculator(domain: domain, range: numbers("Range"), program: program)
        default:
            return nil
        }
    }

    func evaluate(_ input: [Double]) -> [Double] {
        func clip(_ values: [Double], _ bounds: [Double]) -> [Double] {
            values.enumerated().map { i, v in 2 * i + 1 < bounds.count ? min(max(v, bounds[2 * i]), bounds[2 * i + 1]) : v }
        }
        func interpolate(_ x: Double, _ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) -> Double {
            x1 == x0 ? y0 : y0 + (x - x0) * (y1 - y0) / (x1 - x0)
        }
        switch self {
        case .array(let parts):
            return parts.flatMap { $0.evaluate(input).prefix(1) }
        case .exponential(let domain, let c0, let c1, let n):
            let x = clip(Array(input.prefix(1)), domain).first ?? 0
            let p = x <= 0 && n < 1 ? 0 : pow(x, n)
            return zip(c0, c1).map { $0 + p * ($1 - $0) }
        case .stitching(let domain, let functions, let bounds, let encode):
            let x = clip(Array(input.prefix(1)), domain).first ?? 0
            let lo = domain.first ?? 0, hi = domain.count > 1 ? domain[1] : 1
            var k = 0
            while k < bounds.count, x >= bounds[k] { k += 1 }
            k = min(k, functions.count - 1)
            let a = k == 0 ? lo : bounds[k - 1], b = k < bounds.count ? bounds[k] : hi
            let e0 = 2 * k < encode.count ? encode[2 * k] : 0, e1 = 2 * k + 1 < encode.count ? encode[2 * k + 1] : 1
            return functions[k].evaluate([interpolate(x, a, b, e0, e1)])
        case .calculator(let domain, let range, let program):
            let out = PostScriptCalculator.run(program, input: clip(input, domain))
            return clip(Array(out.suffix(max(range.count / 2, 1))), range)
        case .sampled(let domain, let range, let size, let bits, let encode, let decode, let samples):
            let outputs = range.count / 2
            let x = clip(Array(input.prefix(size.count)), domain)
            // The nearest sample in each input dimension (exact for the tint ramps colour spaces hold, close otherwise).
            var offset = 0, stride = 1
            for (i, v) in x.enumerated() where i < size.count {
                let d0 = 2 * i < domain.count ? domain[2 * i] : 0, d1 = 2 * i + 1 < domain.count ? domain[2 * i + 1] : 1
                let e = interpolate(v, d0, d1, encode[safe: 2 * i] ?? 0, encode[safe: 2 * i + 1] ?? Double(size[i] - 1))
                offset += min(max(Int(e.rounded()), 0), size[i] - 1) * stride
                stride *= size[i]
            }
            let maxValue = Double((1 << min(bits, 32)) - 1)
            return (0..<outputs).map { j in
                let raw = Self.sample(samples, index: offset * outputs + j, bits: bits)
                return interpolate(raw, 0, maxValue, decode[safe: 2 * j] ?? range[2 * j], decode[safe: 2 * j + 1] ?? range[2 * j + 1])
            }
        }
    }

    private static func sample(_ data: [UInt8], index: Int, bits: Int) -> Double {
        let bit = index * bits
        var value = 0
        for b in 0..<bits {
            let position = bit + b, byte = position / 8
            guard byte < data.count else { return 0 }
            value = value << 1 | Int(data[byte] >> (7 - UInt8(position % 8)) & 1)
        }
        return Double(value)
    }
}

/// PostScript calculator functions (§7.10.5): numbers, operators and `{ } if` / `{ } { } ifelse`.
enum PostScriptCalculator {
    indirect enum Token: Sendable {
        case number(Double)
        case op(String)
        case block([Token])
    }

    static func parse(_ data: Data) -> [Token]? {
        let text = String(decoding: data, as: UTF8.self)
        var tokens: [String] = []
        var current = ""
        for ch in text {
            if ch == "{" || ch == "}" {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(ch))
            } else if ch.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        var index = 0
        func block() -> [Token]? {
            var out: [Token] = []
            while index < tokens.count {
                let t = tokens[index]
                index += 1
                switch t {
                case "{": guard let inner = block() else { return nil }; out.append(.block(inner))
                case "}": return out
                default: out.append(Double(t).map(Token.number) ?? .op(t))
                }
            }
            return out
        }
        // The program is one outer block.
        guard let outer = block(), outer.count == 1, case .block(let program) = outer[0] else { return nil }
        return program
    }

    static func run(_ program: [Token], input: [Double]) -> [Double] {
        var stack = input
        var steps = 0
        func pop() -> Double { stack.popLast() ?? 0 }
        func exec(_ tokens: [Token]) {
            var i = 0
            while i < tokens.count, steps < 10_000 {
                steps += 1
                switch tokens[i] {
                case .number(let n): stack.append(n)
                case .block:
                    // `{…} if` or `{…} {…} ifelse`.
                    if i + 2 < tokens.count, case .block(let a) = tokens[i], case .block(let b) = tokens[i + 1],
                       case .op("ifelse") = tokens[i + 2] {
                        exec(pop() != 0 ? a : b)
                        i += 2
                    } else if i + 1 < tokens.count, case .block(let a) = tokens[i], case .op("if") = tokens[i + 1] {
                        if pop() != 0 { exec(a) }
                        i += 1
                    }
                case .op(let name): apply(name)
                }
                i += 1
            }
        }
        func apply(_ name: String) {
            switch name {
            case "add": let b = pop(), a = pop(); stack.append(a + b)
            case "sub": let b = pop(), a = pop(); stack.append(a - b)
            case "mul": let b = pop(), a = pop(); stack.append(a * b)
            case "div": let b = pop(), a = pop(); stack.append(b == 0 ? 0 : a / b)
            case "idiv": let b = pop(), a = pop(); stack.append(b == 0 ? 0 : Double(Int(a) / Int(b)))
            case "mod": let b = pop(), a = pop(); stack.append(b == 0 ? 0 : Double(Int(a) % Int(b)))
            case "neg": stack.append(-pop())
            case "abs": stack.append(abs(pop()))
            case "ceiling": stack.append(pop().rounded(.up))
            case "floor": stack.append(pop().rounded(.down))
            case "round": stack.append(pop().rounded())
            case "truncate", "cvi": stack.append(pop().rounded(.towardZero))
            case "cvr": break
            case "sqrt": stack.append(pop().squareRoot())
            case "sin": stack.append(sin(pop() * .pi / 180))
            case "cos": stack.append(cos(pop() * .pi / 180))
            case "atan": let b = pop(), a = pop(); var d = atan2(a, b) * 180 / .pi; if d < 0 { d += 360 }; stack.append(d)
            case "exp": let b = pop(), a = pop(); stack.append(pow(a, b))
            case "ln": stack.append(log(max(pop(), 1e-12)))
            case "log": stack.append(log10(max(pop(), 1e-12)))
            case "pop": _ = pop()
            case "exch": let b = pop(), a = pop(); stack.append(b); stack.append(a)
            case "dup": let a = pop(); stack.append(a); stack.append(a)
            case "copy":
                let n = Int(pop())
                if n > 0, n <= stack.count { stack.append(contentsOf: stack.suffix(n)) }
            case "index":
                let n = Int(pop())
                stack.append(n >= 0 && n < stack.count ? stack[stack.count - 1 - n] : 0)
            case "roll":
                let j = Int(pop()), n = Int(pop())
                guard n > 0, n <= stack.count else { break }
                var part = Array(stack.suffix(n))
                stack.removeLast(n)
                let shift = ((j % n) + n) % n
                part = Array(part.suffix(shift) + part.prefix(n - shift))
                stack.append(contentsOf: part)
            case "eq": let b = pop(), a = pop(); stack.append(a == b ? 1 : 0)
            case "ne": let b = pop(), a = pop(); stack.append(a != b ? 1 : 0)
            case "gt": let b = pop(), a = pop(); stack.append(a > b ? 1 : 0)
            case "ge": let b = pop(), a = pop(); stack.append(a >= b ? 1 : 0)
            case "lt": let b = pop(), a = pop(); stack.append(a < b ? 1 : 0)
            case "le": let b = pop(), a = pop(); stack.append(a <= b ? 1 : 0)
            case "and": let b = pop(), a = pop(); stack.append(a != 0 && b != 0 ? 1 : 0)
            case "or": let b = pop(), a = pop(); stack.append(a != 0 || b != 0 ? 1 : 0)
            case "xor": let b = pop(), a = pop(); stack.append((a != 0) != (b != 0) ? 1 : 0)
            case "not": stack.append(pop() == 0 ? 1 : 0)
            case "true": stack.append(1)
            case "false": stack.append(0)
            case "bitshift": let s = Int(pop()), a = Int(pop()); stack.append(Double(s >= 0 ? a << s : a >> -s))
            default: break
            }
        }
        exec(program)
        return stack
    }
}

fileprivate extension Array {
    subscript(safe index: Int) -> Element? { index >= 0 && index < count ? self[index] : nil }
}
