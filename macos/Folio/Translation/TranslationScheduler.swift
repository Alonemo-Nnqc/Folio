import Foundation

/// Which waiting translation starts next: the first in line whose service has room, while there is room in all.
enum TranslationScheduler {
    static func next(waiting: [String], running: [String], perService: Int, total: Int) -> Int? {
        guard running.count < total else { return nil }
        return waiting.firstIndex { service in running.filter { $0 == service }.count < perService }
    }
}
