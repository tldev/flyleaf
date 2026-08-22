import Foundation

struct ReadingSession: Equatable {
    var start: Date
    var end: Date
    var startPercent: Double
    var endPercent: Double

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var delta: Double { endPercent - startPercent }
}

// Sessions are inferred from Whispersync position deltas alone, which the
// spec calls "nearly free since we're polling anyway".
enum ReadingStats {
    static func sessions(from samples: [PositionSample], maxGap: TimeInterval = 1800) -> [ReadingSession] {
        guard samples.count >= 2 else { return [] }
        var result = [ReadingSession]()
        var current: ReadingSession?

        for (prev, next) in zip(samples, samples.dropFirst()) {
            let gap = next.at.timeIntervalSince(prev.at)
            let advanced = next.percent > prev.percent + 0.001
            let regressed = next.percent < prev.percent - 0.5

            if advanced && gap <= maxGap && gap > 0 {
                if var session = current, prev.at >= session.start, !regressed {
                    session.end = next.at
                    session.endPercent = next.percent
                    current = session
                } else {
                    current = ReadingSession(start: prev.at, end: next.at, startPercent: prev.percent, endPercent: next.percent)
                }
            } else {
                if let session = current, session.delta > 0.05, session.duration >= 60 {
                    result.append(session)
                }
                current = nil
            }
        }
        if let session = current, session.delta > 0.05, session.duration >= 60 {
            result.append(session)
        }
        return result
    }

    static func percentPerHour(_ sessions: [ReadingSession]) -> Double? {
        let usable = sessions.filter { $0.duration >= 120 && $0.delta > 0 }
        guard !usable.isEmpty else { return nil }
        let totalDelta = usable.reduce(0.0) { $0 + $1.delta }
        let totalHours = usable.reduce(0.0) { $0 + $1.duration } / 3600
        guard totalHours > 0 else { return nil }
        return totalDelta / totalHours
    }

    static func projectedFinish(currentPercent: Double, ratePerHour: Double?, dailyMinutes: Double, now: Date) -> Date? {
        guard let ratePerHour, ratePerHour > 0.1, currentPercent < 100, dailyMinutes > 1 else { return nil }
        let remaining = 100 - currentPercent
        let hoursNeeded = remaining / ratePerHour
        let days = hoursNeeded / (dailyMinutes / 60)
        guard days.isFinite, days < 1000 else { return nil }
        return now.addingTimeInterval(days * 86400)
    }

    static func streakDays(samples: [PositionSample], calendar: Calendar = .current, now: Date = Date()) -> Int {
        let daysWithReading = Set(samples.map { calendar.startOfDay(for: $0.at) })
        guard !daysWithReading.isEmpty else { return 0 }
        var streak = 0
        var day = calendar.startOfDay(for: now)
        if !daysWithReading.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day),
                  daysWithReading.contains(yesterday) else { return 0 }
            day = yesterday
        }
        while daysWithReading.contains(day) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    struct Summary: Equatable {
        var minutesToday: Double
        var percentToday: Double
        var ratePerHour: Double?
        var projectedFinish: Date?
        var streakDays: Int
        var sessionCount: Int
    }

    static func summary(
        samples: [PositionSample],
        currentPercent: Double?,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Summary {
        let all = sessions(from: samples)
        let recentCutoff = now.addingTimeInterval(-14 * 86400)
        let recent = all.filter { $0.end >= recentCutoff }
        let rate = percentPerHour(recent)

        let todayStart = calendar.startOfDay(for: now)
        let today = all.filter { $0.end >= todayStart }
        let minutesToday = today.reduce(0.0) { $0 + $1.duration } / 60
        let percentToday = today.reduce(0.0) { $0 + $1.delta }

        let activeDays = Set(recent.map { calendar.startOfDay(for: $0.start) }).count
        let dailyMinutes = activeDays > 0
            ? recent.reduce(0.0) { $0 + $1.duration } / 60 / Double(activeDays)
            : 0

        return Summary(
            minutesToday: minutesToday,
            percentToday: percentToday,
            ratePerHour: rate,
            projectedFinish: projectedFinish(
                currentPercent: currentPercent ?? 0,
                ratePerHour: rate,
                dailyMinutes: dailyMinutes,
                now: now
            ),
            streakDays: streakDays(samples: samples, calendar: calendar, now: now),
            sessionCount: all.count
        )
    }
}
