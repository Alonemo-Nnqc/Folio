import Testing

@Suite struct TranslationSchedulerTests {
    /// Starts everything it can, as `pump` does.
    private func run(_ waiting: [String], perService: Int, total: Int) -> [String] {
        var waiting = waiting, running: [String] = []
        while let index = TranslationScheduler.next(waiting: waiting, running: running, perService: perService, total: total) {
            running.append(waiting.remove(at: index))
        }
        return running
    }

    @Test func oneServiceIsLimitedByItsOwnShare() {
        #expect(run(Array(repeating: "deepseek", count: 6), perService: 2, total: 6) == ["deepseek", "deepseek"])
    }

    @Test func otherServicesDoNotWaitBehindABusyOne() {
        let started = run(["deepseek", "deepseek", "deepseek", "google", "claude", "google"], perService: 2, total: 6)
        #expect(started == ["deepseek", "deepseek", "google", "claude", "google"])
    }

    @Test func theTotalCapsAllServices() {
        let started = run(["a", "b", "c", "d", "e", "f", "g", "h", "i"], perService: 2, total: 8)
        #expect(started.count == 8)
        #expect(TranslationScheduler.next(waiting: ["x"], running: started, perService: 2, total: 8) == nil)
    }

    @Test func orderIsKeptWithinAService() {
        // The first waiting paper of a service with room goes first.
        #expect(TranslationScheduler.next(waiting: ["a", "b", "a"], running: ["a", "a"], perService: 2, total: 6) == 1)
    }
}
