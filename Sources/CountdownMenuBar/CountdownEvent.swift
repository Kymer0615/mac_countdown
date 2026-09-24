import Foundation
import Combine

enum ExternalProvider: String, Codable, CaseIterable, Identifiable {
    case calendar, reminders
    var id: String { rawValue }
    var name: String { self == .calendar ? "Calendar" : "Reminders" }
}

/// Stable identity of one Calendar occurrence or Reminder.
struct SourceKey: Codable, Hashable {
    var provider: ExternalProvider
    var itemID: String
    /// Original occurrence date for recurring Calendar events.
    var occurrence: Date?
}

enum SourceStatus: String, Codable {
    case current, missing, inaccessible
}

/// An incoming Calendar/Reminders item that owns the countdown's title,
/// deadline, and time zone while linked.
struct SourceLink: Codable, Equatable {
    var key: SourceKey
    var containerID: String
    var externalID: String?
    /// Deadline derived from a date-only reminder or all-day event.
    var isDateOnly: Bool
    var completed: Bool
    var status: SourceStatus
    var lastSynced: Date
}

/// An item this app created in Calendar or Reminders.
struct ExportLink: Codable, Equatable {
    var itemID: String
    var fingerprint: String
    var exportedAt: Date
}

struct CountdownEvent: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var date: Date
    var timeZoneIdentifier: String
    /// Immutable creation metadata; the moon uses `startDate`.
    var createdAt: Date
    var startDate: Date
    var critical: CriticalWindow
    var source: SourceLink?
    var calendarExport: ExportLink?
    var reminderExport: ExportLink?

    init(id: UUID = UUID(), title: String, date: Date, timeZoneIdentifier: String = TimeZone.current.identifier,
         createdAt: Date = Date(), startDate: Date? = nil, critical: CriticalWindow = .default) {
        self.id = id
        self.title = title
        self.date = date
        self.timeZoneIdentifier = timeZoneIdentifier
        self.createdAt = createdAt
        self.startDate = startDate ?? Self.fallbackStart(createdAt: createdAt, deadline: date)
        self.critical = critical
    }

    init(id: UUID = UUID(), title: String, date: Date, timeZoneIdentifier: String = TimeZone.current.identifier,
         createdAt: Date = Date(), criticalHours: Double) {
        self.init(id: id, title: title, date: date, timeZoneIdentifier: timeZoneIdentifier,
                  createdAt: createdAt, critical: .unit(.hours, Self.validCriticalHours(criticalHours)))
    }

    static func fallbackStart(createdAt: Date, deadline: Date) -> Date {
        createdAt < deadline ? createdAt : deadline.addingTimeInterval(-1)
    }

    /// v1.2 clamp, applied only when migrating its stored hour values.
    static func validCriticalHours(_ value: Double) -> Double {
        value.isFinite ? min(8760, max(0.1, value)) : 24
    }

    var timeZone: TimeZone {
        EventTimeZone.resolve(timeZoneIdentifier) ?? .current
    }

    var criticalBoundary: Date { critical.boundary(deadline: date, zone: timeZone) }

    /// Shared completion predicate for the menu, window, and widget.
    func isCompleted(at now: Date) -> Bool {
        date <= now || source?.completed == true
    }

    /// Set when a synchronized deadline moved before the configured start.
    var needsStartCorrection: Bool { startDate >= date }

    private enum CodingKeys: String, CodingKey {
        case id, title, date, timeZoneIdentifier, createdAt, criticalHours
        case startDate, critical, source, calendarExport, reminderExport
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        date = try values.decode(Date.self, forKey: .date)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? min(Date(), date)
        startDate = try values.decodeIfPresent(Date.self, forKey: .startDate)
            ?? Self.fallbackStart(createdAt: createdAt, deadline: date)
        if let saved = try? values.decodeIfPresent(CriticalWindow.self, forKey: .critical) {
            critical = saved
        } else {
            critical = .unit(.hours, Self.validCriticalHours(try values.decodeIfPresent(Double.self, forKey: .criticalHours) ?? 24))
        }
        let savedZone = try values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        timeZoneIdentifier = savedZone.flatMap { EventTimeZone.resolve($0) == nil ? nil : $0 }
            ?? TimeZone.current.identifier
        source = try? values.decodeIfPresent(SourceLink.self, forKey: .source)
        calendarExport = try? values.decodeIfPresent(ExportLink.self, forKey: .calendarExport)
        reminderExport = try? values.decodeIfPresent(ExportLink.self, forKey: .reminderExport)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(date, forKey: .date)
        try values.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(startDate, forKey: .startDate)
        try values.encode(critical, forKey: .critical)
        // Lets older versions show an approximate window instead of 24 hours.
        try values.encode(critical.approximateHours(deadline: date, zone: timeZone), forKey: .criticalHours)
        try values.encodeIfPresent(source, forKey: .source)
        try values.encodeIfPresent(calendarExport, forKey: .calendarExport)
        try values.encodeIfPresent(reminderExport, forKey: .reminderExport)
    }

    func exportLink(_ provider: ExternalProvider) -> ExportLink? {
        provider == .calendar ? calendarExport : reminderExport
    }

    mutating func setExportLink(_ link: ExportLink?, for provider: ExternalProvider) {
        if provider == .calendar { calendarExport = link } else { reminderExport = link }
    }

    /// Fields written to exported items; a changed fingerprint means local
    /// edits have not been sent to the linked item.
    var exportFingerprint: String {
        "\(title)|\(date.timeIntervalSince1970)|\(timeZoneIdentifier)"
    }
}

final class EventStore: ObservableObject {
    var onEventsChanged: (() -> Void)?
    private let defaults: UserDefaults
    private let eventsKey = "countdown.events"
    private let selectedIDKey = "countdown.selectedEventID"
    static let backupKey = "countdown.events.backup-v1.2"
    static let unreadableKey = "countdown.events.unreadable"
    static let schemaKey = "countdown.events.schema"
    static let schemaVersion = 2

    @Published private(set) var events: [CountdownEvent] = []
    @Published private(set) var selectedID: UUID?
    /// Set when saved events could not be read. Nothing is written until the
    /// user adds or edits events, and the unreadable data is kept as a backup.
    @Published private(set) var loadError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: eventsKey) {
            do {
                events = try JSONDecoder().decode([CountdownEvent].self, from: data)
                if defaults.integer(forKey: Self.schemaKey) < Self.schemaVersion {
                    // Keep the pre-migration bytes so a failed upgrade is recoverable.
                    if defaults.data(forKey: Self.backupKey) == nil { defaults.set(data, forKey: Self.backupKey) }
                    defaults.set(Self.schemaVersion, forKey: Self.schemaKey)
                    persist()
                }
            } catch {
                loadError = "Saved events could not be read (\(error.localizedDescription)). A backup copy was kept before any change is saved."
                defaults.set(data, forKey: Self.unreadableKey)
            }
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

    func event(_ id: UUID) -> CountdownEvent? { events.first { $0.id == id } }

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

    /// Updates stored data without changing the pinned event, e.g. export links.
    func update(_ id: UUID, _ change: (inout CountdownEvent) -> Void) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        change(&events[index])
        persist()
        onEventsChanged?()
    }

    /// Atomic batch upsert: one write and one change notification, without
    /// pinning any imported event.
    func apply(upserts: [CountdownEvent]) {
        guard !upserts.isEmpty else { return }
        for event in upserts {
            if let index = events.firstIndex(where: { $0.id == event.id }) { events[index] = event }
            else { events.append(event) }
        }
        if selectedEvent == nil { selectedID = sortedEvents.first?.id }
        persist()
        onEventsChanged?()
    }

    func select(_ id: UUID) {
        guard events.contains(where: { $0.id == id }) else { return }
        selectedID = id
        persist()
        onEventsChanged?()
    }

    func deleteSelected() {
        guard let selectedID else { return }
        delete(selectedID)
    }

    func delete(_ id: UUID) {
        events.removeAll { $0.id == id }
        if selectedID == id { selectedID = sortedEvents.first?.id }
        persist()
        onEventsChanged?()
    }

    private func persist() {
        if loadError != nil {
            // The user chose to continue; the unreadable data remains in the backup key.
            loadError = nil
        }
        defaults.set(try? JSONEncoder().encode(events), forKey: eventsKey)
        defaults.set(Self.schemaVersion, forKey: Self.schemaKey)
        defaults.set(selectedID?.uuidString, forKey: selectedIDKey)
        // Publish writes before the widget's separate process reloads its timeline.
        defaults.synchronize()
    }
}
