import Foundation

enum EventTimeZone {
    static let aoeIdentifier = "AoE"
    static let utc = TimeZone(secondsFromGMT: 0)!

    static func resolve(_ identifier: String) -> TimeZone? {
        if identifier == aoeIdentifier { return TimeZone(secondsFromGMT: -12 * 3_600) }
        if identifier == "UTC" { return utc }
        return TimeZone(identifier: identifier)
    }

    static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func offsetLabel(for zone: TimeZone, at date: Date) -> String {
        let offset = zone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "−" : "+"
        let minutes = abs(offset) / 60
        return String(format: "UTC%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }

    static func label(_ identifier: String, at date: Date) -> String {
        guard let zone = resolve(identifier) else { return identifier }
        return "\(identifier) (\(offsetLabel(for: zone, at: date)))"
    }

    private static let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]

    /// Store wall-clock components in a UTC picker so AppKit cannot silently
    /// normalize a nonexistent local time during a daylight-saving transition.
    static func pickerDate(for date: Date, in zone: TimeZone) -> Date {
        let components = calendar(in: zone).dateComponents(fields, from: date)
        return calendar(in: utc).date(from: components)!
    }

    struct Resolution {
        let date: Date
        let isAmbiguous: Bool
    }

    static func interpret(pickerDate: Date, in zone: TimeZone) -> Resolution? {
        let components = calendar(in: utc).dateComponents(fields, from: pickerDate)
        let calendar = calendar(in: zone)
        let searchStart = pickerDate.addingTimeInterval(-2 * 86_400)
        guard let first = calendar.nextDate(
            after: searchStart, matching: components, matchingPolicy: .strict,
            repeatedTimePolicy: .first
        ), calendar.dateComponents(fields, from: first) == components else { return nil }
        let last = calendar.nextDate(
            after: searchStart, matching: components, matchingPolicy: .strict,
            repeatedTimePolicy: .last
        )
        return Resolution(date: first, isAmbiguous: last != nil && last != first)
    }
}
