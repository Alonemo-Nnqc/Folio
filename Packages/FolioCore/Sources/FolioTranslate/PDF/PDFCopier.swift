import CoreGraphics
import Foundation

/// Copies objects of a parsed document (CoreGraphics' `CGPDF*`) into a `PDFWriter`.
///
/// CoreGraphics resolves indirect references and returns the same pointer for the same object, so pointers
/// identify objects: shared fonts and images are written once, and cycles (outline items, annotation parents)
/// terminate. Every dictionary and stream becomes an indirect object; arrays are copied inline. Stream data
/// comes out decoded and is compressed again (JPEG / JPEG 2000 images stay as they are).
/// Encoded stream data by source stream, kept across documents written from the same source (previews, then the
/// final files): images and fonts are decoded and compressed once.
final class StreamDataCache: @unchecked Sendable {
    struct Entry { var payload: Data; var filter: String? }
    private var entries: [Int: Entry] = [:]
    private let lock = NSLock()

    func entry(_ key: Int) -> Entry? { lock.withLock { entries[key] } }
    func store(_ entry: Entry, for key: Int) { lock.withLock { entries[key] = entry } }
}

final class PDFCopier {
    let writer: PDFWriter
    var streamCache: StreamDataCache?
    /// Object number of each copied dictionary / stream, by pointer.
    private var copied: [Int: Int] = [:]
    /// Output page object for each source page dictionary; page references elsewhere point at it.
    var pageMap: [Int: Int] = [:]

    init(writer: PDFWriter) {
        self.writer = writer
    }

    static func key(_ pointer: OpaquePointer) -> Int { Int(bitPattern: UnsafeRawPointer(pointer)) }
    static func key(_ dict: CGPDFDictionaryRef) -> Int { unsafeBitCast(dict, to: Int.self) }
    static func key(_ stream: CGPDFStreamRef) -> Int { unsafeBitCast(stream, to: Int.self) }

    func copy(_ object: CGPDFObjectRef) -> PDFValue {
        switch CGPDFObjectGetType(object) {
        case .null: return .null
        case .boolean:
            var value: CGPDFBoolean = 0
            CGPDFObjectGetValue(object, .boolean, &value)
            return .bool(value != 0)
        case .integer:
            var value: CGPDFInteger = 0
            CGPDFObjectGetValue(object, .integer, &value)
            return .int(value)
        case .real:
            var value: CGPDFReal = 0
            CGPDFObjectGetValue(object, .real, &value)
            return .real(Double(value))
        case .name:
            var value: UnsafePointer<CChar>?
            CGPDFObjectGetValue(object, .name, &value)
            return value.map { .name(String(cString: $0)) } ?? .null
        case .string:
            var value: CGPDFStringRef?
            CGPDFObjectGetValue(object, .string, &value)
            return value.map { .string(Self.data(of: $0)) } ?? .null
        case .array:
            var value: CGPDFArrayRef?
            CGPDFObjectGetValue(object, .array, &value)
            return value.map(copy(array:)) ?? .null
        case .dictionary:
            var value: CGPDFDictionaryRef?
            CGPDFObjectGetValue(object, .dictionary, &value)
            return value.map { copy(dictionary: $0) } ?? .null
        case .stream:
            var value: CGPDFStreamRef?
            CGPDFObjectGetValue(object, .stream, &value)
            return value.map(copy(stream:)) ?? .null
        @unknown default:
            return .null
        }
    }

    func copy(array: CGPDFArrayRef) -> PDFValue {
        var items: [PDFValue] = []
        let count = CGPDFArrayGetCount(array)
        items.reserveCapacity(count)
        for index in 0..<count {
            var object: CGPDFObjectRef?
            if CGPDFArrayGetObject(array, index, &object), let object { items.append(copy(object)) } else { items.append(.null) }
        }
        return .array(items)
    }

    /// The dictionary as an indirect object. Pages become references to their output page (or null when the page
    /// is not in the output); page tree nodes become null.
    func copy(dictionary: CGPDFDictionaryRef) -> PDFValue {
        let key = Self.key(dictionary)
        if let page = pageMap[key] { return .ref(page) }
        if let number = copied[key] { return .ref(number) }
        let type = PDFDictionary.name(dictionary, "Type")
        if type == "Page" || type == "Pages" { return .null }
        let number = writer.reserve()
        copied[key] = number
        writer.set(number, .dict(entries(of: dictionary)))
        return .ref(number)
    }

    /// The dictionary's entries, copied (the dictionary itself is not registered).
    func entries(of dictionary: CGPDFDictionaryRef, skipping skip: Set<String> = []) -> [String: PDFValue] {
        var result: [String: PDFValue] = [:]
        for (name, object) in PDFDictionary.entries(dictionary) where !skip.contains(name) {
            result[name] = copy(object)
        }
        return result
    }

    func copy(stream: CGPDFStreamRef) -> PDFValue {
        let key = Self.key(stream)
        if let number = copied[key] { return .ref(number) }
        let number = writer.reserve()
        copied[key] = number
        var dict: [String: PDFValue] = [:]
        if let source = CGPDFStreamGetDictionary(stream) {
            dict = entries(of: source, skipping: ["Length", "Filter", "DecodeParms", "F", "FFilter", "FDecodeParms", "DL"])
        }
        if let cached = streamCache?.entry(key) {
            if let filter = cached.filter { dict["Filter"] = .name(filter) }
            writer.setStream(number, dict: dict, data: cached.payload, compress: false)
            return .ref(number)
        }
        var format = CGPDFDataFormat.raw
        let data = (CGPDFStreamCopyData(stream, &format) as Data?) ?? Data()
        defer {
            // Remember the encoded payload for the next document from this source.
            if let streamCache, let body = writer.raw(number), let payload = Self.payload(of: body) {
                let filter: String? = switch format {
                case .jpegEncoded: "DCTDecode"
                case .JPEG2000: "JPXDecode"
                default: payload.count == data.count ? nil : "FlateDecode"
                }
                streamCache.store(.init(payload: payload, filter: filter), for: key)
            }
        }
        switch format {
        case .jpegEncoded:
            dict["Filter"] = .name("DCTDecode")
            writer.setStream(number, dict: dict, data: data, compress: false)
        case .JPEG2000:
            dict["Filter"] = .name("JPXDecode")
            writer.setStream(number, dict: dict, data: data, compress: false)
        default:
            writer.setStream(number, dict: dict, data: data)
        }
        return .ref(number)
    }

    /// The bytes between `stream\n` and `\nendstream` of a serialized stream object.
    static func payload(of body: Data) -> Data? {
        guard let start = body.range(of: Data("\nstream\n".utf8)), let end = body.range(of: Data("\nendstream".utf8), options: .backwards),
              start.upperBound <= end.lowerBound else { return nil }
        return body.subdata(in: start.upperBound..<end.lowerBound)
    }

    static func data(of string: CGPDFStringRef) -> Data {
        guard let bytes = CGPDFStringGetBytePtr(string) else { return Data() }
        return Data(bytes: bytes, count: CGPDFStringGetLength(string))
    }
}

/// Small typed accessors for `CGPDFDictionaryRef`.
enum PDFDictionary {
    static func entries(_ dictionary: CGPDFDictionaryRef) -> [(String, CGPDFObjectRef)] {
        final class Box { var items: [(String, CGPDFObjectRef)] = [] }
        let box = Box()
        CGPDFDictionaryApplyBlock(dictionary, { key, object, info in
            let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
            box.items.append((String(cString: key), object))
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.items
    }

    static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    static func dict(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, key, &value) else { return nil }
        return value
    }

    static func array(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &value) else { return nil }
        return value
    }

    static func stream(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFStreamRef? {
        var value: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(dictionary, key, &value) else { return nil }
        return value
    }

    static func object(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var value: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, key, &value) else { return nil }
        return value
    }

    static func number(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Double? {
        var value: CGPDFReal = 0
        guard CGPDFDictionaryGetNumber(dictionary, key, &value) else { return nil }
        return Double(value)
    }

    static func numbers(_ array: CGPDFArrayRef) -> [Double] {
        (0..<CGPDFArrayGetCount(array)).map { index in
            var value: CGPDFReal = 0
            return CGPDFArrayGetNumber(array, index, &value) ? Double(value) : 0
        }
    }

    static func matrix(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGAffineTransform? {
        guard let array = array(dictionary, key) else { return nil }
        let n = numbers(array)
        guard n.count == 6 else { return nil }
        return CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
    }

    static func rect(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGRect? {
        guard let array = array(dictionary, key) else { return nil }
        let n = numbers(array)
        guard n.count == 4 else { return nil }
        return CGRect(x: min(n[0], n[2]), y: min(n[1], n[3]), width: abs(n[2] - n[0]), height: abs(n[3] - n[1]))
    }

    /// An attribute a page inherits from its ancestors (Resources, MediaBox, Rotate …).
    static func inherited(_ page: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var node: CGPDFDictionaryRef? = page
        var depth = 0
        while let current = node, depth < 32 {
            if let value = object(current, key) { return value }
            node = dict(current, "Parent")
            depth += 1
        }
        return nil
    }

    static func resources(of page: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        guard let object = inherited(page, "Resources") else { return nil }
        var value: CGPDFDictionaryRef?
        CGPDFObjectGetValue(object, .dictionary, &value)
        return value
    }

    /// Decoded page content: the stream, or the streams of the array joined with newlines.
    static func contents(of page: CGPDFDictionaryRef) -> Data {
        var data = Data()
        if let stream = stream(page, "Contents") {
            var format = CGPDFDataFormat.raw
            if let bytes = CGPDFStreamCopyData(stream, &format) { data = bytes as Data }
        } else if let array = array(page, "Contents") {
            for index in 0..<CGPDFArrayGetCount(array) {
                var stream: CGPDFStreamRef?
                guard CGPDFArrayGetStream(array, index, &stream), let stream else { continue }
                var format = CGPDFDataFormat.raw
                if let bytes = CGPDFStreamCopyData(stream, &format) {
                    data.append(bytes as Data)
                    data.append(0x0A)
                }
            }
        }
        return data
    }
}
