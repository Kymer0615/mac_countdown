import Foundation

enum MoonProgress {
    enum Phase: Equatable { case notStarted, waning, critical, completed }

    static func phase(for event: CountdownEvent, now: Date) -> Phase {
        if event.isCompleted(at: now) { return .completed }
        if now < event.startDate { return .notStarted }
        return now < event.criticalBoundary ? .waning : .critical
    }

    /// Full before the start, wane from start to the critical boundary, then
    /// fill toward the deadline. When the boundary precedes the start, the
    /// event begins already inside its critical phase.
    static func value(for event: CountdownEvent, now: Date) -> Double {
        let deadline = event.date, start = event.startDate, boundary = event.criticalBoundary
        switch phase(for: event, now: now) {
        case .completed, .notStarted: return 1
        case .waning:
            let span = boundary.timeIntervalSince(start)
            guard span > 0 else { return 0 }
            return clamp(boundary.timeIntervalSince(now) / span)
        case .critical:
            let span = deadline.timeIntervalSince(boundary)
            guard span > 0 else { return 1 }
            return clamp(now.timeIntervalSince(boundary) / span)
        }
    }

    /// Color expresses urgency independently of the moon's fill and never
    /// decreases: green → yellow before the boundary, yellow → red after it.
    static func urgency(for event: CountdownEvent, now: Date) -> Double {
        let deadline = event.date, start = event.startDate, boundary = event.criticalBoundary
        switch phase(for: event, now: now) {
        case .completed: return 1
        case .notStarted: return 0
        case .waning:
            let span = boundary.timeIntervalSince(start)
            return span > 0 ? 0.5 * clamp(now.timeIntervalSince(start) / span) : 0.5
        case .critical:
            let span = deadline.timeIntervalSince(boundary)
            return span > 0 ? 0.5 + 0.5 * clamp(now.timeIntervalSince(boundary) / span) : 1
        }
    }

    /// Text form of the phase, so small changes are readable even when a
    /// 2% change is under a pixel in the menu bar icon.
    static func summary(for event: CountdownEvent, now: Date) -> String {
        let percent = Int((value(for: event, now: now) * 100).rounded())
        switch phase(for: event, now: now) {
        case .notStarted: return "Moon full until start"
        case .waning: return "Moon \(percent)% · waning"
        case .critical: return "Moon \(percent)% · critical"
        case .completed: return "Deadline reached"
        }
    }

    static func hue(progress: Double) -> Double {
        (1 - clamp(progress)) / 3
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}
