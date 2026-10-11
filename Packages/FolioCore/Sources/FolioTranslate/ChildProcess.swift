import Darwin
import Foundation
import Synchronization

/// What a child process should run. Nothing is inherited implicitly: the
/// environment and working directory are always explicit.
public struct ProcessSpec: Sendable, Hashable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: URL

    public init(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

/// One line of output from a child process.
public struct ProcessOutputLine: Sendable, Hashable {
    public enum Stream: Sendable, Hashable { case stdout, stderr }
    public var stream: Stream
    public var text: String
}

/// How a child process ended.
public enum ProcessTermination: Sendable, Hashable {
    case exited(Int32)
    case signaled(Int32)

    public var isSuccess: Bool { self == .exited(0) }
}

public struct ProcessLaunchError: Error, LocalizedError, Sendable {
    public var executable: String
    public var code: Int32
    public var errorDescription: String? {
        "无法启动 \(executable)：\(String(cString: strerror(code)))"
    }
}

/// A child process started with `posix_spawn` in a new process group, so the
/// process and everything it spawns (pdf2zh_next uses multiprocessing workers)
/// can be terminated together with `terminateGroup()`.
///
/// stdin is `/dev/null`; stdout and stderr are pipes read on dedicated threads.
public final class ChildProcess: Sendable {
    public let pid: pid_t
    /// Every line written to stdout / stderr. Finishes when both pipes close.
    public let output: AsyncStream<ProcessOutputLine>
    private let exitTask: Task<ProcessTermination, Never>

    private init(pid: pid_t, output: AsyncStream<ProcessOutputLine>, exitTask: Task<ProcessTermination, Never>) {
        self.pid = pid
        self.output = output
        self.exitTask = exitTask
    }

    public static func launch(_ spec: ProcessSpec) throws -> ChildProcess {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw ProcessLaunchError(executable: spec.executable.path, code: errno) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw ProcessLaunchError(executable: spec.executable.path, code: errno)
        }
        // Keep our pipe ends out of any other process the host app spawns
        // concurrently; otherwise EOF would never arrive.
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir(&fileActions, spec.currentDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = ([spec.executable.path] + spec.arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, spec.executable.path, &fileActions, &attributes, argv, envp)
        close(outPipe[1])
        close(errPipe[1])
        guard result == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw ProcessLaunchError(executable: spec.executable.path, code: result)
        }

        let (stream, continuation) = AsyncStream<ProcessOutputLine>.makeStream(bufferingPolicy: .unbounded)
        let openPipes = Mutex(2)
        let finishOne: @Sendable () -> Void = {
            let remaining = openPipes.withLock { value -> Int in
                value -= 1
                return value
            }
            if remaining == 0 { continuation.finish() }
        }
        for (fd, kind) in [(outPipe[0], ProcessOutputLine.Stream.stdout), (errPipe[0], .stderr)] {
            Thread.detachNewThread {
                readLines(fd: fd) { continuation.yield(ProcessOutputLine(stream: kind, text: $0)) }
                close(fd)
                finishOne()
            }
        }

        let childPID = pid
        let exitTask = Task.detached { () -> ProcessTermination in
            await withCheckedContinuation { (resume: CheckedContinuation<ProcessTermination, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
                    let signal = status & 0x7F
                    resume.resume(returning: signal == 0 ? .exited((status >> 8) & 0xFF) : .signaled(signal))
                }
            }
        }
        // A stray worker that outlives the leader would keep the pipes open and the
        // output stream unfinished; clear the group shortly after the leader exits.
        Task.detached {
            _ = await exitTask.value
            try? await Task.sleep(for: .seconds(2))
            kill(-childPID, SIGKILL)
        }
        return ChildProcess(pid: pid, output: stream, exitTask: exitTask)
    }

    /// Waits for the main process to exit (and reaps it).
    public func waitUntilExit() async -> ProcessTermination {
        await exitTask.value
    }

    /// Sends SIGTERM to the whole process group, then SIGKILL after `grace`
    /// seconds to whatever is left of the group.
    public func terminateGroup(grace: TimeInterval = 3) {
        let group = pid
        kill(-group, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            kill(-group, SIGKILL)
        }
    }

    /// Immediately kills the whole process group.
    public func killGroup() {
        kill(-pid, SIGKILL)
    }

    /// Runs a process to completion and collects its output.
    public static func run(_ spec: ProcessSpec, onLine: (@Sendable (ProcessOutputLine) -> Void)? = nil) async throws -> (termination: ProcessTermination, lines: [ProcessOutputLine]) {
        let process = try launch(spec)
        return await withTaskCancellationHandler {
            var lines: [ProcessOutputLine] = []
            for await line in process.output {
                lines.append(line)
                onLine?(line)
            }
            let termination = await process.waitUntilExit()
            // Make sure no stray children survive the leader.
            kill(-process.pid, SIGKILL)
            return (termination, lines)
        } onCancel: {
            process.terminateGroup(grace: 2)
        }
    }
}

/// Blocking read loop that splits a byte stream into lines.
private func readLines(fd: Int32, onLine: (String) -> Void) {
    var pending: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    func emit(_ bytes: ArraySlice<UInt8>) {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        onLine(line)
    }
    while true {
        let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            pending.append(contentsOf: chunk[0..<count])
            var start = 0
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                emit(pending[start..<newline])
                start = newline + 1
            }
            if start > 0 { pending.removeFirst(start) }
        } else if count < 0 && errno == EINTR {
            continue
        } else {
            break
        }
    }
    if !pending.isEmpty { emit(pending[...]) }
}
