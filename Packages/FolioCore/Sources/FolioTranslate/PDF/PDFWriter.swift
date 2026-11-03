import Compression
import CoreGraphics
import Foundation

/// A PDF object as written to a new file.
indirect enum PDFValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    case name(String)
    case string(Data)
    case array([PDFValue])
    case dict([String: PDFValue])
    case ref(Int)

    static func rect(_ r: CGRect) -> PDFValue {
        .array([.real(r.minX), .real(r.minY), .real(r.maxX), .real(r.maxY)])
    }

    static func matrix(_ t: CGAffineTransform) -> PDFValue {
        .array([.real(t.a), .real(t.b), .real(t.c), .real(t.d), .real(t.tx), .real(t.ty)])
    }

    var dictValue: [String: PDFValue]? {
        if case .dict(let d) = self { return d }
        return nil
    }

    func serialize(into out: inout Data) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let i): out.append(contentsOf: Array(String(i).utf8))
        case .real(let r): out.append(contentsOf: Array(PDFValue.format(r).utf8))
        case .name(let n): PDFValue.appendName(n, to: &out)
        case .string(let s): PDFValue.appendString(s, to: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: " ")) }
                item.serialize(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .dict(let d):
            out.append(contentsOf: Array("<<".utf8))
            // Sorted for reproducible output.
            for key in d.keys.sorted() {
                PDFValue.appendName(key, to: &out)
                out.append(UInt8(ascii: " "))
                d[key]!.serialize(into: &out)
            }
            out.append(contentsOf: Array(">>".utf8))
        case .ref(let n): out.append(contentsOf: Array("\(n) 0 R".utf8))
        }
    }

    /// Plain decimal notation (PDF has no exponents), at most 4 decimals.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        var s = String(format: "%.4f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    static func appendName(_ name: String, to out: inout Data) {
        out.append(UInt8(ascii: "/"))
        for byte in name.utf8 {
            let delimiter = "()<>[]{}/%#".utf8.contains(byte)
            if byte < 33 || byte > 126 || delimiter {
                out.append(contentsOf: Array(String(format: "#%02X", byte).utf8))
            } else {
                out.append(byte)
            }
        }
    }

    static func appendString(_ data: Data, to out: inout Data) {
        out.append(UInt8(ascii: "("))
        for byte in data {
            switch byte {
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"):
                out.append(UInt8(ascii: "\\"))
                out.append(byte)
            case 13: out.append(contentsOf: Array("\\r".utf8))
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: ")"))
    }
}

/// Writes a new PDF file object by object. Objects are numbered from 1; streams are Flate-compressed.
final class PDFWriter {
    /// Serialized object bodies (between `N 0 obj` and `endobj`), indexed by object number - 1.
    private var bodies: [Data?] = []

    var count: Int { bodies.count }

    func reserve() -> Int {
        bodies.append(nil)
        return bodies.count
    }

    func set(_ number: Int, _ value: PDFValue) {
        var data = Data()
        value.serialize(into: &data)
        bodies[number - 1] = data
    }

    @discardableResult
    func add(_ value: PDFValue) -> Int {
        let number = reserve()
        set(number, value)
        return number
    }

    /// A stream object. `encoded` data already carries its filter in `dict`; otherwise the data is compressed here.
    func setStream(_ number: Int, dict: [String: PDFValue], data: Data, compress: Bool = true) {
        var dict = dict
        var payload = data
        if compress, data.count > 64, let deflated = Zlib.compress(data) {
            payload = deflated
            dict["Filter"] = .name("FlateDecode")
        }
        dict["Length"] = .int(payload.count)
        var body = Data()
        PDFValue.dict(dict).serialize(into: &body)
        body.append(contentsOf: Array("\nstream\n".utf8))
        body.append(payload)
        body.append(contentsOf: Array("\nendstream".utf8))
        bodies[number - 1] = body
    }

    /// Stores an already serialized body (reused between preview writes).
    func setRaw(_ number: Int, _ body: Data) { bodies[number - 1] = body }
    func raw(_ number: Int) -> Data? { bodies[number - 1] }

    @discardableResult
    func addStream(dict: [String: PDFValue], data: Data, compress: Bool = true) -> Int {
        let number = reserve()
        setStream(number, dict: dict, data: data, compress: compress)
        return number
    }

    /// The complete file. Unset objects are written as `null`.
    func finish(root: Int, info: Int?) -> Data {
        var out = Data()
        out.append(contentsOf: Array("%PDF-1.7\n%".utf8))
        out.append(contentsOf: [0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = []
        offsets.reserveCapacity(bodies.count)
        for (index, body) in bodies.enumerated() {
            offsets.append(out.count)
            out.append(contentsOf: Array("\(index + 1) 0 obj\n".utf8))
            if let body { out.append(body) } else { out.append(contentsOf: Array("null".utf8)) }
            out.append(contentsOf: Array("\nendobj\n".utf8))
        }
        let xref = out.count
        var table = "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        out.append(contentsOf: Array(table.utf8))
        var trailer: [String: PDFValue] = ["Size": .int(bodies.count + 1), "Root": .ref(root)]
        if let info { trailer["Info"] = .ref(info) }
        out.append(contentsOf: Array("trailer\n".utf8))
        PDFValue.dict(trailer).serialize(into: &out)
        out.append(contentsOf: Array("\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }
}

/// zlib (RFC 1950) streams for FlateDecode, built on the Compression framework's raw DEFLATE.
enum Zlib {
    static func compress(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 8 + 1024
        var out = Data(count: capacity + 6)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                guard let s = src.bindMemory(to: UInt8.self).baseAddress,
                      let d = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d + 2, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out[0] = 0x78
        out[1] = 0x9C
        let sum = adler32(data)
        out[2 + written] = UInt8(sum >> 24)
        out[3 + written] = UInt8((sum >> 16) & 0xFF)
        out[4 + written] = UInt8((sum >> 8) & 0xFF)
        out[5 + written] = UInt8(sum & 0xFF)
        out.count = written + 6
        return out
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                // 5552 is the largest block that cannot overflow before the modulo.
                let end = min(index + 5552, bytes.count)
                while index < end {
                    a &+= UInt32(bytes[index])
                    b &+= a
                    index += 1
                }
                a %= 65521
                b %= 65521
            }
        }
        return (b << 16) | a
    }
}
