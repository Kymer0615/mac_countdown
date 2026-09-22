import Foundation

enum CountdownFormat {
    static func compact(until target: Date, now: Date = Date()) -> String {
        let remaining = target.timeIntervalSince(now)
        guard remaining > 0 else { return "Done" }
        let seconds = Int(remaining)
        if remaining >= 7 * 86_400 {
            return "\(seconds / 86_400)d"
        }
        if remaining >= 86_400 {
            return "\(seconds / 86_400)d \((seconds % 86_400) / 3_600)h"
        }
        if remaining >= 3_600 {
            return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
        }
        let roundedSeconds = Int(ceil(remaining))
        return "\(roundedSeconds / 60)m \(roundedSeconds % 60)s"
    }

    static func remaining(until target: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard target > now else { return "Done" }

        // Whole seconds keep the display stable between timer ticks. Rounding up
        // ensures an event does not display Done before its exact target time.
        let seconds = ceil(target.timeIntervalSince(now))
        let roundedNow = target.addingTimeInterval(-seconds)
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: roundedNow,
            to: target
        )
        let units: [(Int?, String)] = [
            (parts.year, "y"), (parts.month, "mo"), (parts.day, "d"),
            (parts.hour, "h"), (parts.minute, "m"), (parts.second, "s")
        ]
        let result = units.compactMap { value, unit -> String? in
            guard let value, value > 0 else { return nil }
            return "\(value)\(unit)"
        }
        return result.isEmpty ? "<1s" : result.joined(separator: " ")
    }
}
