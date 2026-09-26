import Foundation

/// Races an operation against a timeout.
enum Deadline {
    /// The operation's result, or nil when `timeout` elapsed first (the operation is then cancelled).
    static func run<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
