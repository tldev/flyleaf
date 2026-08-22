import Foundation

@MainActor
final class PositionPoller {
    private var task: Task<Void, Never>?
    private unowned let state: AppState

    init(state: AppState) {
        self.state = state
    }

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        log(.poller, "Poller started")
        task = Task { [weak state] in
            while !Task.isCancelled {
                guard let state else { return }
                await state.pollOnce()
                var interval = PollPolicy.interval(
                    now: Date(),
                    lastAdvanceAt: state.lastAdvanceAt,
                    activeSeconds: Prefs.shared.pollActiveSeconds,
                    idleSeconds: Prefs.shared.pollIdleSeconds
                )
                // A personal document is only ever read while the reader has
                // the app open, so keep it responsive (check about once a
                // minute) instead of drifting to the long idle cadence, while
                // still honoring the overnight back-off.
                if state.currentBook?.isPersonalDoc == true, interval < 3000 {
                    interval = min(interval, 60)
                }
                let wait = PollPolicy.jittered(interval)
                log(.poller, .debug, "Next poll in \(Int(wait))s")
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        log(.poller, "Poller stopped")
    }

    func pollSoon() {
        stop()
        start()
    }
}
