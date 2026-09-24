import Foundation

@main
struct CountdownFormatChecks {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12))!
        let target = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 12))!
        precondition(CountdownFormat.remaining(until: target, now: start, calendar: calendar) == "1mo 1d")

        let exact = Date(timeIntervalSince1970: 1_000)
        precondition(CountdownFormat.remaining(until: exact, now: exact) == "Done")
        precondition(CountdownFormat.remaining(until: exact, now: exact.addingTimeInterval(-0.2)) == "1s")

        let day: TimeInterval = 86_400
        let cases: [(TimeInterval, String)] = [
            (49 * day, "49d"), (18 * day, "18d"), (3 * day + 8 * 3_600, "3d 8h"),
            (8 * 3_600 + 24 * 60, "8h 24m"), (24 * 60 + 16, "24m 16s"),
            (30 * day + 1, "30d"), (30 * day, "30d"), (30 * day - 1, "29d"),
            (7 * day + 1, "7d"), (7 * day, "7d"), (7 * day - 1, "6d 23h"),
            (day + 1, "1d 0h"), (day, "1d 0h"), (day - 1, "23h 59m"),
            (3_601, "1h 0m"), (3_600, "1h 0m"), (3_599, "59m 59s"),
            (0.2, "0m 1s"), (0, "Done"), (-1, "Done")
        ]
        for (seconds, expected) in cases {
            let actual = CountdownFormat.compact(until: exact.addingTimeInterval(seconds), now: exact)
            precondition(actual == expected, "\(seconds): expected \(expected), got \(actual)")
        }
        print("Progressive precision and calendar countdown checks passed")

        let creation = Date(timeIntervalSince1970: 100000)
        let lifetime = CountdownEvent(title: "60-day event", date: creation.addingTimeInterval(60 * day), createdAt: creation)
        precondition(MoonProgress.value(for: lifetime, now: creation) == 1)
        precondition(abs(MoonProgress.value(for: lifetime, now: creation.addingTimeInterval(29.5 * day)) - 0.5) < 0.000001)
        precondition(MoonProgress.value(for: lifetime, now: lifetime.date.addingTimeInterval(-day)) == 0)
        precondition(MoonProgress.value(for: lifetime, now: lifetime.date.addingTimeInterval(-day / 2)) == 0.5)
        precondition(MoonProgress.value(for: lifetime, now: lifetime.date) == 1)
        precondition(MoonProgress.value(for: lifetime, now: creation.addingTimeInterval(-day)) == 1)
        var custom = lifetime
        custom.criticalHours = 48
        precondition(MoonProgress.value(for: custom, now: custom.date.addingTimeInterval(-2 * day)) == 0)
        precondition(MoonProgress.value(for: custom, now: custom.date.addingTimeInterval(-day)) == 0.5)
        let short = CountdownEvent(title: "Short", date: creation.addingTimeInterval(3600), createdAt: creation)
        precondition(MoonProgress.value(for: short, now: creation) > 0.95)
        let urgencies = (0...120).map { MoonProgress.urgency(for: lifetime, now: creation.addingTimeInterval(Double($0) * day / 2)) }
        precondition(urgencies == urgencies.sorted(), "Urgency color must never reverse while the moon wanes")
        precondition(urgencies.first == 0 && urgencies.last == 1)
        precondition(CountdownEvent.validCriticalHours(.nan) == 24)
        precondition(CountdownEvent.validCriticalHours(-1) == 0.1)
        precondition(CountdownEvent.validCriticalHours(100000) == 8760)
        print("Creation-based moon, critical threshold, and monotonic urgency checks passed")

        let iso = ISO8601DateFormatter()
        func date(_ value: String) -> Date { iso.date(from: value)! }
        let wallTime = date("2026-09-22T23:59:59Z")
        let aoe = EventTimeZone.resolve("AoE")!
        let utc = EventTimeZone.utc
        precondition(EventTimeZone.interpret(pickerDate: wallTime, in: utc)!.date == wallTime)
        let aoeDate = EventTimeZone.interpret(pickerDate: wallTime, in: aoe)!.date
        precondition(aoeDate == date("2026-09-23T11:59:59Z"))
        precondition(EventTimeZone.pickerDate(for: aoeDate, in: aoe) == wallTime)
        precondition(aoe.secondsFromGMT(for: date("2026-01-01T00:00:00Z")) == -43_200)
        precondition(aoe.secondsFromGMT(for: date("2026-07-01T00:00:00Z")) == -43_200)

        let london = EventTimeZone.resolve("Europe/London")!
        precondition(EventTimeZone.interpret(pickerDate: date("2026-03-29T01:30:00Z"), in: london) == nil)
        let repeated = EventTimeZone.interpret(pickerDate: date("2026-10-25T01:30:00Z"), in: london)!
        precondition(repeated.isAmbiguous)
        precondition(repeated.date == date("2026-10-25T00:30:00Z"))
        precondition(EventTimeZone.offsetLabel(for: london, at: repeated.date) == "UTC+01:00")
        let summer = EventTimeZone.interpret(pickerDate: date("2026-07-01T12:00:00Z"), in: london)!
        precondition(summer.date == date("2026-07-01T11:00:00Z"))
        precondition(!summer.isAmbiguous)
        let kolkata = EventTimeZone.resolve("Asia/Kolkata")!
        precondition(EventTimeZone.offsetLabel(for: kolkata, at: wallTime) == "UTC+05:30")
        precondition(EventTimeZone.interpret(pickerDate: wallTime, in: kolkata)!.date == wallTime.addingTimeInterval(-19_800))
        print("UTC, AoE, named zone, and daylight-saving checks passed")

        struct LegacyEvent: Encodable { let id: UUID; let title: String; let date: Date }
        let legacy = LegacyEvent(id: UUID(), title: "Existing event", date: wallTime)
        let decoder = JSONDecoder()
        let migrated = try decoder.decode(CountdownEvent.self, from: JSONEncoder().encode(legacy))
        precondition(migrated.id == legacy.id && migrated.date == legacy.date)
        precondition(migrated.timeZoneIdentifier == TimeZone.current.identifier)
        precondition(migrated.criticalHours == 24 && migrated.createdAt <= migrated.date)
        let suite = "countdown.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "countdown.events")
        let migratedStore = EventStore(defaults: defaults)
        let savedCreation = migratedStore.events[0].createdAt
        precondition(EventStore(defaults: defaults).events[0].createdAt == savedCreation)
        var changed = migratedStore.events[0]
        changed.title = "Edited"
        changed.criticalHours = 48
        migratedStore.save(changed)
        precondition(EventStore(defaults: defaults).events[0].createdAt == savedCreation)
        precondition(EventStore(defaults: defaults).events[0].criticalHours == 48)
        let event = CountdownEvent(title: "AoE deadline", date: aoeDate, timeZoneIdentifier: "AoE")
        let restored = try decoder.decode(CountdownEvent.self, from: JSONEncoder().encode(event))
        precondition(restored == event)
        print("Legacy migration and time zone persistence checks passed")

        let widgetNow = date("2026-09-23T12:00:00Z")
        let widgetEvents = (0..<15).map { index in
            CountdownEvent(title: "Event \(index)", date: widgetNow.addingTimeInterval(Double(index - 2) * 3_600))
        }
        let ordered = WidgetEventData.ordered(widgetEvents, now: widgetNow)
        precondition(ordered.first!.title == "Event 3")
        precondition(ordered.suffix(3).map(\.title) == ["Event 2", "Event 1", "Event 0"])
        for capacity in [1, 2, 6] {
            let first = WidgetEventPage(events: widgetEvents, requestedPage: 0, capacity: capacity, now: widgetNow)
            let pages = (0..<first.count).map {
                WidgetEventPage(events: widgetEvents, requestedPage: $0, capacity: capacity, now: widgetNow)
            }
            precondition(pages.flatMap(\.events).map(\.id) == ordered.map(\.id), "Every event must be reachable exactly once")
            precondition(pages.allSatisfy { $0.events.count <= capacity })
            precondition(WidgetEventPage(events: widgetEvents, requestedPage: 999, capacity: capacity, now: widgetNow).index == first.count - 1)
        }
        let empty = WidgetEventPage(events: [], requestedPage: 9, capacity: 6, now: widgetNow)
        precondition(empty.events.isEmpty && empty.index == 0 && empty.count == 1)
        let shrunk = WidgetEventPage(events: [widgetEvents[0]], requestedPage: 10, capacity: 6, now: widgetNow)
        precondition(shrunk.index == 0 && shrunk.events.count == 1)
        precondition(WidgetEventPage(events: widgetEvents, requestedPage: -1, capacity: 6, now: widgetNow).index == 0)

        let upcoming = CountdownEvent(title: "Soon", date: widgetNow.addingTimeInterval(17))
        let precisionChange = CountdownEvent(title: "Precision", date: widgetNow.addingTimeInterval(3_617))
        let timelineDates = WidgetEventData.timelineDates(events: [upcoming, precisionChange], now: widgetNow)
        precondition(timelineDates == timelineDates.sorted())
        precondition(Set(timelineDates).count == timelineDates.count)
        precondition(timelineDates.first == widgetNow && timelineDates.last == widgetNow.addingTimeInterval(3_600))
        precondition(timelineDates.contains(upcoming.date))
        precondition(timelineDates.contains(widgetNow.addingTimeInterval(18)))
        let link = WidgetEventData.eventURL(upcoming)
        precondition(link.scheme == "countdownmenubar" && link.host == "event" && link.lastPathComponent == upcoming.id.uuidString)
        print("Widget paging, ordering, timeline, deletion, and deep-link checks passed")
    }
}
