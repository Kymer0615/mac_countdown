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
        precondition(lifetime.startDate == creation)
        precondition(MoonProgress.value(for: lifetime, now: creation) == 1)
        precondition(abs(MoonProgress.value(for: lifetime, now: creation.addingTimeInterval(29.5 * day)) - 0.5) < 0.000001)
        precondition(MoonProgress.value(for: lifetime, now: lifetime.date.addingTimeInterval(-day)) == 0)
        precondition(MoonProgress.value(for: lifetime, now: lifetime.date.addingTimeInterval(-day / 2)) == 0.5)
        precondition(MoonProgress.value(for: lifetime, now: lifetime.date) == 1)
        precondition(MoonProgress.value(for: lifetime, now: creation.addingTimeInterval(-day)) == 1)
        precondition(MoonProgress.phase(for: lifetime, now: creation.addingTimeInterval(-1)) == .notStarted)
        precondition(MoonProgress.urgency(for: lifetime, now: creation.addingTimeInterval(-day)) == 0)
        var custom = lifetime
        custom.critical = .unit(.hours, 48)
        precondition(MoonProgress.value(for: custom, now: custom.date.addingTimeInterval(-2 * day)) == 0)
        precondition(MoonProgress.value(for: custom, now: custom.date.addingTimeInterval(-day)) == 0.5)
        let short = CountdownEvent(title: "Short", date: creation.addingTimeInterval(3600), createdAt: creation)
        precondition(short.criticalBoundary < short.startDate, "A 24-hour window before a 1-hour event starts critical")
        precondition(MoonProgress.phase(for: short, now: creation) == .critical)
        precondition(MoonProgress.value(for: short, now: creation) > 0.95)
        let urgencies = (0...120).map { MoonProgress.urgency(for: lifetime, now: creation.addingTimeInterval(Double($0) * day / 2)) }
        precondition(urgencies == urgencies.sorted(), "Urgency color must never reverse while the moon wanes")
        precondition(urgencies.first == 0 && urgencies.last == 1)
        precondition(CountdownEvent.validCriticalHours(.nan) == 24)
        precondition(CountdownEvent.validCriticalHours(-1) == 0.1)
        precondition(CountdownEvent.validCriticalHours(100000) == 8760)

        // Explicit start, independent of creation metadata.
        let future = CountdownEvent(title: "Future start", date: creation.addingTimeInterval(20 * day), createdAt: creation,
                                    startDate: creation.addingTimeInterval(10 * day), critical: .unit(.days, 5))
        precondition(future.createdAt == creation)
        precondition(MoonProgress.value(for: future, now: creation) == 1 && MoonProgress.phase(for: future, now: creation) == .notStarted)
        precondition(MoonProgress.value(for: future, now: future.startDate) == 1)
        precondition(abs(MoonProgress.value(for: future, now: creation.addingTimeInterval(12.5 * day)) - 0.5) < 1e-9)
        precondition(MoonProgress.value(for: future, now: future.criticalBoundary) == 0)
        precondition(abs(MoonProgress.value(for: future, now: creation.addingTimeInterval(17.5 * day)) - 0.5) < 1e-9)
        precondition(MoonProgress.phase(for: future, now: future.date) == .completed)
        let futureUrgency = stride(from: 0.0, through: 21, by: 0.25).map { MoonProgress.urgency(for: future, now: creation.addingTimeInterval($0 * day)) }
        precondition(futureUrgency == futureUrgency.sorted() && futureUrgency.first == 0 && futureUrgency.last == 1)
        // Before the critical window: fill = remaining time to the boundary / (boundary − start).
        for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
            let span = future.criticalBoundary.timeIntervalSince(future.startDate)
            let instant = future.startDate.addingTimeInterval(fraction * span)
            let expected = future.criticalBoundary.timeIntervalSince(instant) / span
            precondition(abs(MoonProgress.value(for: future, now: instant) - expected) < 1e-9)
        }
        precondition(MoonProgress.summary(for: future, now: creation.addingTimeInterval(12.5 * day)) == "Moon 50% · waning")
        precondition(MoonProgress.summary(for: future, now: creation) == "Moon full until start")
        var lateStart = future
        lateStart.startDate = creation.addingTimeInterval(18 * day)
        precondition(MoonProgress.phase(for: lateStart, now: lateStart.startDate) == .critical, "Boundary before start begins critical")
        precondition(abs(MoonProgress.value(for: lateStart, now: lateStart.startDate) - 0.6) < 1e-9, "Configured window is not shortened")
        var invalidStart = future
        invalidStart.startDate = future.date.addingTimeInterval(day)
        precondition(invalidStart.needsStartCorrection)
        _ = MoonProgress.value(for: invalidStart, now: creation) // must not crash
        print("Start-based moon, critical threshold, and monotonic urgency checks passed")

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
        precondition(migrated.critical == .unit(.hours, 24) && migrated.createdAt <= migrated.date)
        precondition(migrated.startDate < migrated.date)
        let suite = "countdown.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyData = try JSONEncoder().encode([legacy])
        defaults.set(legacyData, forKey: "countdown.events")
        let migratedStore = EventStore(defaults: defaults)
        precondition(defaults.data(forKey: EventStore.backupKey) == legacyData, "Pre-migration data is backed up")
        let savedCreation = migratedStore.events[0].createdAt
        let savedStart = migratedStore.events[0].startDate
        precondition(EventStore(defaults: defaults).events[0].createdAt == savedCreation)
        precondition(EventStore(defaults: defaults).events[0].startDate == savedStart, "Repeated loads do not shift the baseline")
        var changed = migratedStore.events[0]
        changed.title = "Edited"
        changed.critical = .unit(.hours, 48)
        migratedStore.save(changed)
        precondition(EventStore(defaults: defaults).events[0].createdAt == savedCreation)
        precondition(EventStore(defaults: defaults).events[0].critical == .unit(.hours, 48))
        let event = CountdownEvent(title: "AoE deadline", date: aoeDate, timeZoneIdentifier: "AoE")
        let restored = try decoder.decode(CountdownEvent.self, from: JSONEncoder().encode(event))
        precondition(restored == event)

        // v1.1 and v1.2 shapes keep IDs, exact deadlines, zones, creation, and hours.
        let v11 = #"[{"id":"6E0B7E5C-8A7B-4F53-9C3A-9E1B2C3D4E5F","title":"v1.1","date":800000000,"timeZoneIdentifier":"AoE"}]"#
        let v12 = #"[{"id":"7E0B7E5C-8A7B-4F53-9C3A-9E1B2C3D4E5F","title":"v1.2","date":800000000.25,"timeZoneIdentifier":"Europe/London","createdAt":799000000,"criticalHours":0.5}]"#
        let old11 = try decoder.decode([CountdownEvent].self, from: Data(v11.utf8))[0]
        precondition(old11.timeZoneIdentifier == "AoE" && old11.date == Date(timeIntervalSinceReferenceDate: 800000000))
        let old12 = try decoder.decode([CountdownEvent].self, from: Data(v12.utf8))[0]
        precondition(old12.id.uuidString == "7E0B7E5C-8A7B-4F53-9C3A-9E1B2C3D4E5F" && old12.date == Date(timeIntervalSinceReferenceDate: 800000000.25))
        precondition(old12.createdAt == Date(timeIntervalSinceReferenceDate: 799000000) && old12.startDate == old12.createdAt)
        precondition(old12.critical == .unit(.hours, 0.5) && old12.criticalBoundary == old12.date.addingTimeInterval(-1800))
        let lateCreation = #"[{"id":"8E0B7E5C-8A7B-4F53-9C3A-9E1B2C3D4E5F","title":"late","date":800000000,"createdAt":800000500}]"#
        let late = try decoder.decode([CountdownEvent].self, from: Data(lateCreation.utf8))[0]
        precondition(late.startDate == late.date.addingTimeInterval(-1), "Start fallback stays before the deadline")
        let selectedSuite = "countdown.tests.sel.\(UUID().uuidString)"
        let selectedDefaults = UserDefaults(suiteName: selectedSuite)!
        defer { selectedDefaults.removePersistentDomain(forName: selectedSuite) }
        selectedDefaults.set(Data(v12.utf8), forKey: "countdown.events")
        selectedDefaults.set("7E0B7E5C-8A7B-4F53-9C3A-9E1B2C3D4E5F", forKey: "countdown.selectedEventID")
        precondition(EventStore(defaults: selectedDefaults).selectedID?.uuidString == "7E0B7E5C-8A7B-4F53-9C3A-9E1B2C3D4E5F")
        // Newer files still carry an hour approximation for older readers.
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old12)) as! [String: Any]
        precondition(written["criticalHours"] as? Double == 0.5 && written["startDate"] != nil)

        // Unreadable data is reported and never overwritten by an empty list.
        let brokenSuite = "countdown.tests.broken.\(UUID().uuidString)"
        let brokenDefaults = UserDefaults(suiteName: brokenSuite)!
        defer { brokenDefaults.removePersistentDomain(forName: brokenSuite) }
        let garbage = Data("not json".utf8)
        brokenDefaults.set(garbage, forKey: "countdown.events")
        let brokenStore = EventStore(defaults: brokenDefaults)
        precondition(brokenStore.loadError != nil && brokenStore.events.isEmpty)
        precondition(brokenDefaults.data(forKey: "countdown.events") == garbage)
        precondition(brokenDefaults.data(forKey: EventStore.unreadableKey) == garbage)

        // Batch upserts write once, notify once, and never change the pin.
        var notifications = 0
        migratedStore.onEventsChanged = { notifications += 1 }
        let pinned = migratedStore.selectedID
        migratedStore.apply(upserts: (0..<5).map { CountdownEvent(title: "Batch \($0)", date: wallTime.addingTimeInterval(Double($0) * 60)) })
        precondition(notifications == 1 && migratedStore.selectedID == pinned && migratedStore.events.count == 6)
        precondition(EventStore(defaults: defaults).events.count == 6)
        print("Migration, backup, time zone persistence, and batch update checks passed")

        // Critical window units.
        let deadlineUTC = date("2026-03-31T12:00:00Z")
        func boundary(_ window: CriticalWindow, _ deadline: Date = deadlineUTC, _ zone: TimeZone = utc) -> Date? {
            if case .success(let resolution) = window.resolve(deadline: deadline, zone: zone) { return resolution.date }
            return nil
        }
        func failure(_ window: CriticalWindow, _ deadline: Date = deadlineUTC, _ zone: TimeZone = utc) -> CriticalWindow.Failure? {
            if case .failure(let failure) = window.resolve(deadline: deadline, zone: zone) { return failure }
            return nil
        }
        precondition(boundary(.unit(.seconds, 1)) == deadlineUTC.addingTimeInterval(-1))
        precondition(boundary(.unit(.minutes, 1.5)) == deadlineUTC.addingTimeInterval(-90))
        precondition(boundary(.unit(.hours, 0.25)) == deadlineUTC.addingTimeInterval(-900))
        precondition(boundary(.unit(.hours, 1.0 / 7200)) == deadlineUTC.addingTimeInterval(-1), "Fractions resolve to whole seconds")
        precondition(boundary(.unit(.months, 1)) == date("2026-02-28T12:00:00Z"), "March 31 minus a month clamps to February")
        precondition(boundary(.unit(.months, 1), date("2024-03-31T12:00:00Z")) == date("2024-02-29T12:00:00Z"), "Leap year")
        precondition(boundary(.unit(.days, 1.5)) == date("2026-03-30T00:00:00Z"))
        precondition(boundary(.custom(months: 1, days: 2, hours: 3, minutes: 4, seconds: 5)) == date("2026-02-26T08:55:55Z"))
        precondition(boundary(.unit(.hours, 24), deadlineUTC, aoe) == deadlineUTC.addingTimeInterval(-86_400))
        precondition(boundary(.unit(.days, 1), deadlineUTC, aoe) == deadlineUTC.addingTimeInterval(-86_400), "AoE has no DST")
        precondition(boundary(.exact(deadlineUTC.addingTimeInterval(-5))) == deadlineUTC.addingTimeInterval(-5))
        precondition(failure(.exact(deadlineUTC)) == .notBeforeDeadline)
        precondition(failure(.unit(.seconds, 0)) == .invalidValue && failure(.unit(.hours, -1)) == .invalidValue)
        precondition(failure(.unit(.hours, .nan)) == .invalidValue && failure(.unit(.hours, .infinity)) == .invalidValue)
        precondition(failure(.unit(.seconds, 0.4)) == .invalidValue, "Rounds to zero seconds")
        precondition(failure(.unit(.months, 1.5)) == .invalidValue)
        precondition(failure(.custom(months: 0, days: 0, hours: 0, minutes: 0, seconds: 0)) == .invalidValue)
        precondition(failure(.custom(months: -1, days: 0, hours: 0, minutes: 0, seconds: 5)) == .invalidValue)
        precondition(failure(.custom(months: 0, days: 0, hours: Int.max, minutes: 0, seconds: 0)) == .overflow)
        precondition(failure(.unit(.hours, 1e300)) == .overflow)
        precondition(failure(.unit(.days, 1e12)) == .overflow)
        precondition(boundary(.unit(.hours, 10_000)) != nil, "No undocumented 8760-hour limit")
        // London springs forward on 29 March 2026: that day is 23 hours long.
        let londonDeadline = date("2026-03-29T12:00:00Z") // 13:00 BST
        precondition(boundary(.unit(.days, 1), londonDeadline, london) == date("2026-03-28T13:00:00Z"), "1 day keeps 13:00 GMT")
        precondition(boundary(.unit(.hours, 24), londonDeadline, london) == date("2026-03-28T12:00:00Z"), "24 hours is elapsed")
        let fallDeadline = date("2026-10-25T12:00:00Z") // 12:00 GMT, a 25-hour day
        precondition(fallDeadline.timeIntervalSince(boundary(.unit(.days, 1), fallDeadline, london)!) == 25 * 3600)
        precondition(failure(.unit(.days, 1), date("2026-03-30T00:30:00Z"), london) == .nonexistentTime, "01:30 on 29 March is skipped")
        if case .success(let repeatedBoundary) = CriticalWindow.unit(.days, 1).resolve(deadline: date("2026-10-26T01:30:00Z"), zone: london) {
            precondition(repeatedBoundary.isAmbiguous && repeatedBoundary.date == date("2026-10-25T00:30:00Z"), "First of two occurrences")
        } else { preconditionFailure("Repeated times resolve") }
        // Display resolution never fails, even for a skipped time after sync.
        let lenient = CriticalWindow.unit(.days, 1).boundary(deadline: date("2026-03-30T00:30:00Z"), zone: london)
        precondition(lenient < date("2026-03-30T00:30:00Z"))
        precondition(CriticalWindow.exact(deadlineUTC.addingTimeInterval(10)).boundary(deadline: deadlineUTC, zone: utc) == deadlineUTC)
        precondition(CriticalWindow.unit(.hours, 1).label == "1 hour" && CriticalWindow.unit(.days, 2.5).label == "2.5 days")
        precondition(CriticalWindow.custom(months: 1, days: 0, hours: 2, minutes: 0, seconds: 3).label == "1mo 2h 3s")
        for window in [CriticalWindow.unit(.minutes, 2.5), .custom(months: 1, days: 2, hours: 3, minutes: 4, seconds: 5), .exact(deadlineUTC)] {
            let roundTrip = try decoder.decode(CriticalWindow.self, from: JSONEncoder().encode(window))
            precondition(roundTrip == window)
        }
        print("Critical window unit, month-end, leap-year, DST, AoE, exact, and overflow checks passed")

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
        let critical = CountdownEvent(title: "Critical soon", date: widgetNow.addingTimeInterval(3 * 3_600), critical: .unit(.minutes, 150))
        precondition(WidgetEventData.timelineDates(events: [critical], now: widgetNow).contains(widgetNow.addingTimeInterval(1_800)), "Critical boundary is a timeline entry")
        var reminderDone = CountdownEvent(title: "Reminder done", date: widgetNow.addingTimeInterval(86_400))
        reminderDone.source = SourceLink(key: SourceKey(provider: .reminders, itemID: "r1"), containerID: "l", externalID: nil,
                                         isDateOnly: false, completed: true, status: .current, lastSynced: widgetNow)
        precondition(reminderDone.isCompleted(at: widgetNow) && CountdownFormat.compact(for: reminderDone, now: widgetNow) == "Done")
        precondition(MoonProgress.phase(for: reminderDone, now: widgetNow) == .completed)
        precondition(WidgetEventData.ordered([reminderDone, upcoming], now: widgetNow).map(\.title) == ["Soon", "Reminder done"])
        reminderDone.source?.completed = false
        precondition(!reminderDone.isCompleted(at: widgetNow), "Reopening removes the completion override")
        let link = WidgetEventData.eventURL(upcoming)
        precondition(link.scheme == "countdownmenubar" && link.host == "event" && link.lastPathComponent == upcoming.id.uuidString)
        print("Widget paging, ordering, timeline, deletion, and deep-link checks passed")
    }
}
