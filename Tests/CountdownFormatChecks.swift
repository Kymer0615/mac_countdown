import Foundation

@main
struct CountdownFormatChecks {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12))!
        let target = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 12))!
        precondition(CountdownFormat.remaining(until: target, now: start, calendar: calendar) == "1mo 1d")

        let exact = Date(timeIntervalSince1970: 1_000)
        precondition(CountdownFormat.remaining(until: exact, now: exact) == "Done")
        precondition(CountdownFormat.remaining(until: exact, now: exact.addingTimeInterval(-0.2)) == "1s")
        print("Countdown format checks passed")
    }
}
