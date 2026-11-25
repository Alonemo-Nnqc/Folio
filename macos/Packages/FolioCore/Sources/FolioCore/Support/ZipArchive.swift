import Foundation
import zlib

public enum ZipError: Error, LocalizedError {
    case notAnArchive, unsupported, damaged(String)

    public var errorDescription: String? {
        switch self {
        case .notAnArchive: String(localized: "文件已损坏，或不是 Folio 文献库包", bundle: .module)
        case .unsupported: String(localized: "不支持这个压缩包的格式", bundle: .module)
        case .damaged(let name): String(localized: "压缩包中的「\(name)」已损坏", bundle: .module)
        }
    }
}

/// Writes a zip file of any size (zip64 where needed), each entry stored as it is: papers are compressed already.
final class ZipWriter {
    private struct Entry { var name: Data; var crc: UInt32; var size: UInt64; var offset: UInt64; var time: (UInt16, UInt16) }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var position: UInt64 = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle.close() }

    func add(_ data: Data, as name: String) throws {
        try begin(name, date: Date(), size: UInt64(data.count))
        try write(data)
        try end(crc: Self.crc(data, 0), size: UInt64(data.count), expected: UInt64(data.count))
    }

    /// `check` is called between chunks and may throw to stop.
    func add(contentsOf url: URL, as name: String, check: () throws -> Void = {}) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let expected = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        try begin(name, date: attributes[.modificationDate] as? Date ?? Date(), size: expected)
        var crc: UInt32 = 0, size: UInt64 = 0
        while try autoreleasepool(invoking: {
            guard let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            crc = Self.crc(chunk, crc)
            size += UInt64(chunk.count)
            try write(chunk)
            return true
        }) { try check() }
        try end(crc: crc, size: size, expected: expected)
    }

    /// The list of what is in the archive; without it the file is no archive.
    func finish() throws {
        let start = position
        for entry in entries {
            var extra = Data()
            if entry.size >= 0xFFFF_FFFF || entry.offset >= 0xFFFF_FFFF {
                extra.put(UInt16(1)); extra.put(UInt16(24))
                extra.put(entry.size); extra.put(entry.size); extra.put(entry.offset)
            }
            let wide = !extra.isEmpty
            var record = Data()
            record.put(UInt32(0x0201_4B50))
            // Made on Unix, a plain file; names are UTF-8.
            record.put(UInt16(3 << 8 | 45)); record.put(UInt16(45))
            record.put(UInt16(0x0800)); record.put(UInt16(0))
            record.put(entry.time.0); record.put(entry.time.1)
            record.put(entry.crc)
            record.put(wide ? UInt32.max : UInt32(entry.size)); record.put(wide ? UInt32.max : UInt32(entry.size))
            record.put(UInt16(entry.name.count)); record.put(UInt16(extra.count)); record.put(UInt16(0))
            record.put(UInt16(0)); record.put(UInt16(0)); record.put(UInt32(0o100644 << 16))
            record.put(wide ? UInt32.max : UInt32(entry.offset))
            try write(record + entry.name + extra)
        }
        let size = position - start
        var tail = Data()
        if entries.count >= 0xFFFF || start >= 0xFFFF_FFFF || size >= 0xFFFF_FFFF {
            let at = position
            tail.put(UInt32(0x0606_4B50)); tail.put(UInt64(44)); tail.put(UInt16(45)); tail.put(UInt16(45))
            tail.put(UInt32(0)); tail.put(UInt32(0))
            tail.put(UInt64(entries.count)); tail.put(UInt64(entries.count)); tail.put(size); tail.put(start)
            tail.put(UInt32(0x0706_4B50)); tail.put(UInt32(0)); tail.put(at); tail.put(UInt32(1))
        }
        tail.put(UInt32(0x0605_4B50)); tail.put(UInt16(0)); tail.put(UInt16(0))
        let count = UInt16(min(entries.count, 0xFFFF))
        tail.put(count); tail.put(count)
        tail.put(UInt32(min(size, 0xFFFF_FFFF))); tail.put(UInt32(min(start, 0xFFFF_FFFF))); tail.put(UInt16(0))
        try write(tail)
        try handle.synchronize()
        try handle.close()
    }

    private func begin(_ name: String, date: Date, size: UInt64) throws {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(parts.year ?? 1980, 1980), 2107) - 1980
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        let entry = Entry(name: Data(name.utf8), crc: 0, size: size, offset: position, time: (time, day))
        entries.append(entry)
        try write(header(entry))
    }

    private func header(_ entry: Entry) -> Data {
        var extra = Data()
        let wide = entry.size >= 0xFFFF_FFFF
        if wide { extra.put(UInt16(1)); extra.put(UInt16(16)); extra.put(entry.size); extra.put(entry.size) }
        var record = Data()
        record.put(UInt32(0x0403_4B50)); record.put(UInt16(45)); record.put(UInt16(0x0800)); record.put(UInt16(0))
        record.put(entry.time.0); record.put(entry.time.1)
        record.put(entry.crc)
        record.put(wide ? UInt32.max : UInt32(entry.size)); record.put(wide ? UInt32.max : UInt32(entry.size))
        record.put(UInt16(entry.name.count)); record.put(UInt16(extra.count))
        return record + entry.name + extra
    }

    /// Now that what was written is known, its header says so.
    private func end(crc: UInt32, size: UInt64, expected: UInt64) throws {
        var entry = entries[entries.count - 1]
        // Grown past 4 GB while it was read: its header has no room for that.
        guard (size >= 0xFFFF_FFFF) == (expected >= 0xFFFF_FFFF) else { throw ZipError.unsupported }
        entry.crc = crc
        entry.size = size
        entries[entries.count - 1] = entry
        try handle.seek(toOffset: entry.offset)
        try handle.write(contentsOf: header(entry))
        try handle.seek(toOffset: position)
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        position += UInt64(data.count)
    }

    static func crc(_ data: Data, _ before: UInt32) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(uLong(before), $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
    }
}

/// Reads a zip file: entries stored or deflated.
final class ZipReader {
    private struct Entry { var method: UInt16; var crc: UInt32; var packed: UInt64; var size: UInt64; var offset: UInt64 }

    private let handle: FileHandle
    private var entries: [String: Entry] = [:]

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        try readDirectory()
    }

    deinit { try? handle.close() }

    /// The same name may be written composed or not (é), as the system it comes from does.
    private static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping }

    func contains(_ name: String) -> Bool { entries[Self.key(name)] != nil }

    func data(_ name: String) throws -> Data {
        var result = Data()
        try read(name) { result.append($0) }
        return result
    }

    func extract(_ name: String, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try read(name) { try output.write(contentsOf: $0) }
    }

    private func read(_ name: String, _ body: (Data) throws -> Void) throws {
        guard let entry = entries[Self.key(name)] else { throw ZipError.damaged(name) }
        let header = try bytes(at: entry.offset, 30)
        guard header.get32(0) == 0x0403_4B50 else { throw ZipError.damaged(name) }
        try handle.seek(toOffset: entry.offset + 30 + UInt64(header.get16(26)) + UInt64(header.get16(28)))
        var crc: UInt32 = 0, size: UInt64 = 0
        func emit(_ data: Data) throws {
            crc = ZipWriter.crc(data, crc)
            size += UInt64(data.count)
            try body(data)
        }
        func chunks(_ each: (Data) throws -> Void) throws {
            var left = entry.packed
            while left > 0 {
                try autoreleasepool {
                    guard let chunk = try handle.read(upToCount: Int(min(left, 1 << 20))), !chunk.isEmpty else { throw ZipError.damaged(name) }
                    left -= UInt64(chunk.count)
                    try each(chunk)
                }
            }
        }
        switch entry.method {
        case 0: try chunks(emit)
        case 8:
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZipError.unsupported }
            defer { inflateEnd(&stream) }
            var output = [UInt8](repeating: 0, count: 1 << 20)
            try chunks { chunk in
                var input = [UInt8](chunk)
                try input.withUnsafeMutableBufferPointer { source in
                    stream.next_in = source.baseAddress
                    stream.avail_in = uInt(source.count)
                    repeat {
                        let (status, produced) = output.withUnsafeMutableBufferPointer { target -> (Int32, Int) in
                            stream.next_out = target.baseAddress
                            stream.avail_out = uInt(target.count)
                            let status = inflate(&stream, Z_NO_FLUSH)
                            return (status, target.count - Int(stream.avail_out))
                        }
                        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else { throw ZipError.damaged(name) }
                        if produced > 0 { try emit(Data(output[0..<produced])) }
                        if status == Z_STREAM_END || produced == 0 { break }
                    } while stream.avail_in > 0 || stream.avail_out == 0
                }
            }
        default: throw ZipError.unsupported
        }
        guard crc == entry.crc, size == entry.size else { throw ZipError.damaged(name) }
    }

    private func bytes(at offset: UInt64, _ count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw ZipError.notAnArchive }
        return Data(data)
    }

    private func readDirectory() throws {
        let length = try handle.seekToEnd()
        let tailLength = Int(min(length, 65_557))
        guard tailLength >= 22 else { throw ZipError.notAnArchive }
        let tail = try bytes(at: length - UInt64(tailLength), tailLength)
        guard let at = stride(from: tailLength - 22, through: 0, by: -1).first(where: { tail.get32($0) == 0x0605_4B50 }) else { throw ZipError.notAnArchive }
        var count = UInt64(tail.get16(at + 10)), size = UInt64(tail.get32(at + 12)), start = UInt64(tail.get32(at + 16))
        if at >= 20, tail.get32(at - 20) == 0x0706_4B50 {
            let end = try bytes(at: tail.get64(at - 12), 56)
            guard end.get32(0) == 0x0606_4B50 else { throw ZipError.notAnArchive }
            count = end.get64(32); size = end.get64(40); start = end.get64(48)
        }
        guard start <= length, size <= length - start else { throw ZipError.notAnArchive }
        let directory = try bytes(at: start, Int(size))
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= directory.count, directory.get32(p) == 0x0201_4B50 else { throw ZipError.notAnArchive }
            let nameLength = Int(directory.get16(p + 28)), extraLength = Int(directory.get16(p + 30)), comment = Int(directory.get16(p + 32))
            guard p + 46 + nameLength + extraLength + comment <= directory.count else { throw ZipError.notAnArchive }
            var entry = Entry(method: directory.get16(p + 10), crc: directory.get32(p + 16), packed: UInt64(directory.get32(p + 20)),
                              size: UInt64(directory.get32(p + 24)), offset: UInt64(directory.get32(p + 42)))
            guard directory.get16(p + 8) & 1 == 0 else { throw ZipError.unsupported }
            var x = p + 46 + nameLength
            let extraEnd = x + extraLength
            while x + 4 <= extraEnd {
                let kind = directory.get16(x), fieldEnd = min(x + 4 + Int(directory.get16(x + 2)), extraEnd)
                var field = x + 4
                // The values that did not fit, in this order.
                if kind == 1 {
                    func next(_ value: inout UInt64) {
                        if value == 0xFFFF_FFFF, field + 8 <= fieldEnd { value = directory.get64(field); field += 8 }
                    }
                    next(&entry.size); next(&entry.packed); next(&entry.offset)
                }
                x = fieldEnd
            }
            entries[Self.key(String(decoding: directory[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self))] = entry
            p += 46 + nameLength + extraLength + comment
        }
    }
}

private extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    func get16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
    func get32(_ at: Int) -> UInt32 { UInt32(get16(at)) | UInt32(get16(at + 2)) << 16 }
    func get64(_ at: Int) -> UInt64 { UInt64(get32(at)) | UInt64(get32(at + 4)) << 32 }
}
