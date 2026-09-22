import Foundation

struct CountdownEvent: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var date: Date

    init(id: UUID = UUID(), title: String, date: Date) {
        self.id = id
        self.title = title
        self.date = date
    }
}

final class EventStore {
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
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(events), forKey: eventsKey)
        defaults.set(selectedID?.uuidString, forKey: selectedIDKey)
    }
}
