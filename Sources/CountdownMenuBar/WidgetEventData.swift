import Foundation

enum WidgetEventData {
    static let kind = "CountdownEvents"
    static let appDomain = "com.local.CountdownMenuBar"
    static let eventsKey = "countdown.events"

    static func eventURL(_ event: CountdownEvent) -> URL {
        URL(string: "countdownmenubar://event/\(event.id.uuidString)")!
    }

    /// Used by the sandboxed widget, which has read-only access to this one
    /// preference domain. All event mutations remain in the containing app.
    static func loadEvents() throws -> [CountdownEvent] {
        CFPreferencesAppSynchronize(appDomain as CFString)
        guard let data = CFPreferencesCopyAppValue(eventsKey as CFString, appDomain as CFString) as? Data else {
            return []
        }
        return try JSONDecoder().decode([CountdownEvent].self, from: data)
    }

    static func ordered(_ events: [CountdownEvent], now: Date) -> [CountdownEvent] {
        events.sorted { lhs, rhs in
            let lhsDone = lhs.date <= now
            let rhsDone = rhs.date <= now
            if lhsDone != rhsDone { return !lhsDone }
            if lhs.date != rhs.date { return lhsDone ? lhs.date > rhs.date : lhs.date < rhs.date }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Minute entries plus exact precision/deadline boundaries. WidgetKit owns
    /// execution timing; the final-hour timer text is rendered by the system.
    static func timelineDates(events: [CountdownEvent], now: Date) -> [Date] {
        let end = now.addingTimeInterval(3_600)
        var dates = Set((0...60).map { now.addingTimeInterval(Double($0) * 60) })
        for event in events {
            for threshold: TimeInterval in [7 * 86_400, 86_400, 3_600, 0] {
                let boundary = event.date.addingTimeInterval(-threshold)
                if boundary > now && boundary <= end {
                    dates.insert(boundary)
                    // Enter the next precision band immediately after a boundary.
                    let after = boundary.addingTimeInterval(1)
                    if after <= end { dates.insert(after) }
                }
            }
        }
        return dates.sorted()
    }
}

struct WidgetEventPage {
    let events: [CountdownEvent]
    let index: Int
    let count: Int
    let totalEvents: Int

    init(events: [CountdownEvent], requestedPage: Int, capacity: Int, now: Date) {
        let capacity = max(1, capacity)
        let ordered = WidgetEventData.ordered(events, now: now)
        totalEvents = ordered.count
        count = max(1, (ordered.count + capacity - 1) / capacity)
        index = min(max(0, requestedPage), count - 1)
        self.events = Array(ordered.dropFirst(index * capacity).prefix(capacity))
    }
}
