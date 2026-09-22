import Foundation

struct CountdownEvent: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var date: Date
    var timeZoneIdentifier: String

    init(id: UUID = UUID(), title: String, date: Date, timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.id = id
        self.title = title
        self.date = date
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    var timeZone: TimeZone {
        EventTimeZone.resolve(timeZoneIdentifier) ?? .current
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, date, timeZoneIdentifier
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        date = try values.decode(Date.self, forKey: .date)
        let savedZone = try values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        timeZoneIdentifier = savedZone.flatMap { EventTimeZone.resolve($0) == nil ? nil : $0 }
            ?? TimeZone.current.identifier
    }
}

final class EventStore {
    var onEventsChanged: (() -> Void)?
    private let defaults: UserDefaults
    private let eventsKey = "countdown.events"
    private let selectedIDKey = "countdown.selectedEventID"

    private(set) var events: [CountdownEvent] = []
    private(set) var selectedID: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: eventsKey),
           let decoded = try? JSONDecoder().decode([CountdownEvent].self, from: data) {
            events = decoded
        }
        if let value = defaults.string(forKey: selectedIDKey) {
            selectedID = UUID(uuidString: value)
        }
        if selectedEvent == nil {
            selectedID = sortedEvents.first?.id
        }
        // Persist the assigned zone for legacy events without changing their instants.
        if !events.isEmpty { persist() }
    }

    var sortedEvents: [CountdownEvent] {
        events.sorted {
            if $0.date == $1.date { return $0.title < $1.title }
            return $0.date < $1.date
        }
    }

    var selectedEvent: CountdownEvent? {
        events.first { $0.id == selectedID }
    }

    func save(_ event: CountdownEvent) {
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            events.append(event)
        }
        selectedID = event.id
        persist()
        onEventsChanged?()
    }

    func select(_ id: UUID) {
        guard events.contains(where: { $0.id == id }) else { return }
        selectedID = id
        persist()
    }

    func deleteSelected() {
        guard let selectedID else { return }
        events.removeAll { $0.id == selectedID }
        self.selectedID = sortedEvents.first?.id
        persist()
        onEventsChanged?()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(events), forKey: eventsKey)
        defaults.set(selectedID?.uuidString, forKey: selectedIDKey)
        // Publish writes before the widget's separate process reloads its timeline.
        defaults.synchronize()
    }
}
