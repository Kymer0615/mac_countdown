import Foundation

enum MoonProgress {
    /// Wane from creation to the critical window, then wax toward the deadline.
    static func value(for event: CountdownEvent, now: Date) -> Double {
        let remaining = event.date.timeIntervalSince(now)
        if remaining <= 0 { return 1 }
        let critical = CountdownEvent.validCriticalHours(event.criticalHours) * 3600
        if remaining <= critical { return min(1, max(0, 1 - remaining / critical)) }
        let span = event.date.timeIntervalSince(event.createdAt) - critical
        guard span > 0 else { return 1 }
        return min(1, max(0, (remaining - critical) / span))
    }

    /// Color expresses urgency independently of the waxing/waning geometry.
    static func urgency(for event: CountdownEvent, now: Date) -> Double {
        let remaining = event.date.timeIntervalSince(now)
        let critical = CountdownEvent.validCriticalHours(event.criticalHours) * 3600
        if remaining <= critical { return 0.5 + 0.5 * min(1, max(0, 1 - remaining / critical)) }
        return 0.5 * (1 - value(for: event, now: now))
    }

    static func hue(progress: Double) -> Double {
        (1 - min(1, max(0, progress))) / 3
    }
}
