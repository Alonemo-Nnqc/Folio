import Foundation

/// The MCP stdio transport: newline-delimited JSON-RPC on the process's standard streams.
///
/// - Input is split on LF bytes only. Foundation's `lines` also breaks on U+2028 / U+2029 / NEL, which
///   JSON allows unescaped inside strings (and Node-based clients send raw), so a message containing
///   text copied from a PDF used to arrive as two halves and the request was never answered.
/// - Protocol output goes to a private duplicate of the original stdout, and file descriptor 1 is
///   pointed at stderr, so a stray `print` anywhere in the libraries can never corrupt the stream.
public final class StdioTransport: Sendable {
    private let writer: LineWriter

    /// Takes over stdout. Call once, before anything else prints.
    public init() {
        let protocolOutput = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        writer = LineWriter(handle: FileHandle(fileDescriptor: protocolOutput, closeOnDealloc: true))
    }

    /// Test seam: writes to `handle` and leaves the process's streams alone.
    init(output handle: FileHandle) {
        writer = LineWriter(handle: handle)
    }

    /// Messages from `input` (stdin by default), one per line; ends when the stream closes.
    public static func messages(from input: FileHandle = .standardInput) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task.detached {
                var line = Data()
                do {
                    for try await byte in input.bytes {
                        if byte == 0x0A {
                            if line.last == 0x0D { line.removeLast() }
                            if !line.isEmpty { continuation.yield(line) }
                            line = Data()
                        } else {
                            line.append(byte)
                        }
                    }
                } catch {
                    log("stdin: \(error.localizedDescription)")
                }
                if !line.isEmpty { continuation.yield(line) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(_ message: JSONValue) async {
        await writer.write(message.wireLine)
    }

    /// Diagnostics for the client's log (stderr is never part of the protocol).
    public static func log(_ text: String) {
        FileHandle.standardError.write(Data("[folio-mcp] \(text)\n".utf8))
    }
}

/// Serialises whole lines so concurrent responses never interleave.
actor LineWriter {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ line: String) {
        do {
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            // The client went away; the read loop ends on its own when stdin closes.
            StdioTransport.log("stdout: \(error.localizedDescription)")
        }
    }
}
