import Foundation

// Cadence from the spec: 45-60s while a session is active, 10 minute idle
// backoff, suspended overnight. Pure so it can be unit tested.
enum PollPolicy {
    static let activeWindow: TimeInterval = 20 * 60
    static let overnightIdleThreshold: TimeInterval = 2 * 60 * 60

    static func interval(
        now: Date,
        lastAdvanceAt: Date?,
        activeSeconds: Int,
        idleSeconds: Int,
        calendar: Calendar = .current
    ) -> TimeInterval {
        let hour = calendar.component(.hour, from: now)
        let isOvernight = hour >= 1 && hour < 7
        let idleFor = lastAdvanceAt.map { now.timeIntervalSince($0) } ?? .infinity

        if isOvernight && idleFor > overnightIdleThreshold {
            return 3600
        }
        if idleFor <= activeWindow {
            return TimeInterval(max(30, activeSeconds))
        }
        return TimeInterval(max(60, idleSeconds))
    }

    static func jittered(_ interval: TimeInterval, random: Double = Double.random(in: 0...1)) -> TimeInterval {
        // Plus or minus 15 percent so polls never fall into lockstep.
        let spread = interval * 0.3
        return interval - spread / 2 + spread * random
    }
}
