import Foundation

enum CriticalUnit: String, Codable, CaseIterable, Identifiable {
    case seconds, minutes, hours, days, months
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// How far before the deadline the critical (filling) phase begins.
/// Seconds, minutes, and hours are elapsed time; days and months are
/// calendar components in the event's time zone.
enum CriticalWindow: Codable, Equatable {
    case unit(CriticalUnit, Double)
    case custom(months: Int, days: Int, hours: Int, minutes: Int, seconds: Int)
    case exact(Date)

    static let `default` = CriticalWindow.unit(.hours, 24)

    enum Failure: Error, Equatable {
        case invalidValue, nonexistentTime, notBeforeDeadline, overflow

        var message: String {
            switch self {
            case .invalidValue: return "Enter a critical window of at least one second. Months must be whole numbers."
            case .nonexistentTime: return "The critical boundary falls on a clock time skipped by daylight saving. Choose a different window."
            case .notBeforeDeadline: return "The critical boundary must be before the deadline."
            case .overflow: return "The critical window is too large to calculate."
            }
        }
    }

    struct Resolution: Equatable {
        let date: Date
        let isAmbiguous: Bool
    }

    /// Strict resolution used by editors: rejects skipped clock times and
    /// chooses the first occurrence of repeated ones.
    func resolve(deadline: Date, zone: TimeZone) -> Result<Resolution, Failure> {
        let months: Int, days: Int, elapsed: Double
        switch self {
        case .exact(let date):
            return date < deadline ? .success(Resolution(date: date, isAmbiguous: false)) : .failure(.notBeforeDeadline)
        case .unit(let unit, let value):
            guard value.isFinite, value > 0 else { return .failure(.invalidValue) }
            switch unit {
            case .seconds: (months, days, elapsed) = (0, 0, value)
            case .minutes: (months, days, elapsed) = (0, 0, value * 60)
            case .hours: (months, days, elapsed) = (0, 0, value * 3_600)
            case .days:
                let whole = value.rounded(.down)
                guard whole < Double(Int32.max) else { return .failure(.overflow) }
                (months, days, elapsed) = (0, Int(whole), (value - whole) * 86_400)
            case .months:
                guard value == value.rounded(), value < Double(Int32.max) else { return .failure(.invalidValue) }
                (months, days, elapsed) = (Int(value), 0, 0)
            }
        case .custom(let m, let d, let h, let min, let s):
            guard [m, d, h, min, s].allSatisfy({ $0 >= 0 }) else { return .failure(.invalidValue) }
            let (hours, o1) = h.multipliedReportingOverflow(by: 3_600)
            let (minutes, o2) = min.multipliedReportingOverflow(by: 60)
            guard !o1, !o2 else { return .failure(.overflow) }
            (months, days, elapsed) = (m, d, Double(hours) + Double(minutes) + Double(s))
        }
        let seconds = elapsed.rounded()
        guard seconds.isFinite, seconds < 1e15 else { return .failure(.overflow) }
        guard months > 0 || days > 0 || seconds >= 1 else { return .failure(.invalidValue) }

        var anchor = Resolution(date: deadline, isAmbiguous: false)
        if months > 0 || days > 0 {
            // Calendar arithmetic on wall-clock fields, then the same strict
            // interpretation the date editor uses.
            let wallClock = EventTimeZone.pickerDate(for: deadline, in: zone)
            let utc = EventTimeZone.calendar(in: EventTimeZone.utc)
            guard let shiftedMonths = utc.date(byAdding: .month, value: -months, to: wallClock),
                  let shifted = utc.date(byAdding: .day, value: -days, to: shiftedMonths),
                  shifted.timeIntervalSince1970.isFinite else { return .failure(.overflow) }
            guard let interpreted = EventTimeZone.interpret(pickerDate: shifted, in: zone) else {
                return .failure(.nonexistentTime)
            }
            anchor = Resolution(date: interpreted.date, isAmbiguous: interpreted.isAmbiguous)
        }
        let boundary = anchor.date.addingTimeInterval(-seconds)
        guard boundary.timeIntervalSinceReferenceDate.isFinite, boundary > .distantPast else { return .failure(.overflow) }
        guard boundary < deadline else { return .failure(.notBeforeDeadline) }
        return .success(Resolution(date: boundary, isAmbiguous: anchor.isAmbiguous))
    }

    /// Lenient resolution for display and moon phases. Saved values were
    /// validated, but a synchronized deadline can later move onto a skipped
    /// clock time; then Foundation's forward adjustment is used.
    func boundary(deadline: Date, zone: TimeZone) -> Date {
        if case .success(let resolution) = resolve(deadline: deadline, zone: zone) { return resolution.date }
        switch self {
        case .exact(let date): return min(date, deadline)
        case .custom(let m, let d, _, _, _) where m >= 0 && d >= 0:
            let calendar = EventTimeZone.calendar(in: zone)
            let shifted = calendar.date(byAdding: DateComponents(month: -m, day: -d), to: deadline) ?? deadline
            if case .custom(_, _, let h, let min, let s) = self {
                return shifted.addingTimeInterval(-Double(h * 3_600 + min * 60 + s))
            }
            return shifted
        case .unit(.days, let value) where value.isFinite && value > 0 && value < 1e7:
            let calendar = EventTimeZone.calendar(in: zone)
            let whole = value.rounded(.down)
            let shifted = calendar.date(byAdding: .day, value: -Int(whole), to: deadline) ?? deadline
            return shifted.addingTimeInterval(-((value - whole) * 86_400).rounded())
        case .unit(.months, let value) where value.isFinite && value > 0 && value < 1e7:
            return EventTimeZone.calendar(in: zone).date(byAdding: .month, value: -Int(value), to: deadline) ?? deadline
        default:
            return deadline.addingTimeInterval(-86_400)
        }
    }

    var label: String {
        func number(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
        }
        switch self {
        case .unit(let unit, let value):
            let name = value == 1 ? String(unit.rawValue.dropLast()) : unit.rawValue
            return "\(number(value)) \(name)"
        case .custom(let m, let d, let h, let min, let s):
            let parts = [(m, "mo"), (d, "d"), (h, "h"), (min, "m"), (s, "s")].filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }
            return parts.isEmpty ? "0s" : parts.joined(separator: " ")
        case .exact:
            return "exact time"
        }
    }

    /// Legacy elapsed-hour approximation written for older app versions.
    func approximateHours(deadline: Date, zone: TimeZone) -> Double {
        max(1.0 / 3_600, deadline.timeIntervalSince(boundary(deadline: deadline, zone: zone)) / 3_600)
    }
}
