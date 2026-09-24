import EventKit
import Foundation

/// Authorization reported by macOS. `unknown` is never treated as permission.
enum AccessStatus: String, Equatable {
    case notDetermined, denied, restricted, writeOnly, fullAccess, unknown

    var label: String {
        switch self {
        case .notDetermined: return "Not requested"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .writeOnly: return "Add-only access"
        case .fullAccess: return "Full access"
        case .unknown: return "Unknown"
        }
    }
}

struct ServiceAccess: Equatable {
    let provider: ExternalProvider
    let status: AccessStatus

    /// Write-only Calendar access still permits adding events.
    var canCreate: Bool { status == .fullAccess || (provider == .calendar && status == .writeOnly) }
    var canRead: Bool { status == .fullAccess }
    var canRequest: Bool { status == .notDetermined || (provider == .calendar && status == .writeOnly) }
}

struct ExternalContainer: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let provider: ExternalProvider
}

/// Plain values copied from EventKit; EventKit objects are never persisted.
struct ExternalItem: Identifiable, Equatable {
    let key: SourceKey
    let externalID: String?
    let containerID: String
    let containerTitle: String
    let title: String
    /// Calendar start or reminder due date; nil for undated reminders.
    let deadline: Date?
    let timeZoneIdentifier: String?
    let isDateOnly: Bool
    let isCompleted: Bool
    let url: URL?

    var id: SourceKey { key }
}

/// Values written to Calendar/Reminders for an exported countdown.
struct ExternalDraft: Equatable {
    let title: String
    let deadline: Date
    let timeZone: TimeZone
    let url: URL
}

enum ItemLookup: Equatable {
    case found(ExternalItem)
    /// The container is readable but the item no longer exists.
    case deleted
    /// Access, account, or container problems; the item may still exist.
    case inaccessible
}

enum IntegrationFailure: LocalizedError, Equatable {
    case notAuthorized(ExternalProvider), noDestination(ExternalProvider), itemMissing(ExternalProvider)
    case ambiguous(ExternalProvider), system(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized(let p): return "\(p.name) access is not available. Allow it in Events & Settings → Settings."
        case .noDestination(let p): return p == .calendar ? "Set up a default calendar in Calendar first." : "Set up a default list in Reminders first."
        case .itemMissing(let p): return "The linked \(p == .calendar ? "Calendar event" : "reminder") no longer exists."
        case .ambiguous(let p): return "Several \(p.name) items link to this countdown. Remove the duplicates in \(p.name), then try again."
        case .system(let message): return message
        }
    }
}

/// Every EventKit operation the app performs, injectable for tests so they
/// never prompt for or touch personal calendars.
@MainActor
protocol EventKitAdapter: AnyObject {
    func status(_ provider: ExternalProvider) -> AccessStatus
    func requestFullAccess(_ provider: ExternalProvider) async -> Bool
    func containers(_ provider: ExternalProvider) -> [ExternalContainer]
    func events(from start: Date, to end: Date, containerIDs: Set<String>) -> [ExternalItem]
    func reminders(containerIDs: Set<String>) async -> [ExternalItem]
    /// Looks up one tracked item, including items outside any query range.
    func lookup(_ key: SourceKey, containerID: String) async -> ItemLookup
    /// Items carrying this URL near the deadline; requires read access.
    func items(linking url: URL, provider: ExternalProvider, near date: Date) async -> [ExternalItem]
    func create(_ provider: ExternalProvider, _ draft: ExternalDraft) throws -> String
    func update(_ provider: ExternalProvider, itemID: String, _ draft: ExternalDraft) throws
    /// Resets cached EventKit state after authorization or store changes.
    func reset()
}

@MainActor
final class LiveEventKitAdapter: EventKitAdapter {
    private var store = EKEventStore()

    private func type(_ provider: ExternalProvider) -> EKEntityType { provider == .calendar ? .event : .reminder }

    func status(_ provider: ExternalProvider) -> AccessStatus {
        let status = EKEventStore.authorizationStatus(for: type(provider))
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        default:
            if #available(macOS 14, *) {
                if status == .fullAccess { return .fullAccess }
                if status == .writeOnly { return .writeOnly }
                return .unknown
            }
            // `.authorized` on macOS 13 grants full access.
            return status.rawValue == 3 ? .fullAccess : .unknown
        }
    }

    func requestFullAccess(_ provider: ExternalProvider) async -> Bool {
        do {
            let granted: Bool
            if #available(macOS 14, *) {
                granted = provider == .calendar ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
            } else {
                granted = try await store.requestAccess(to: type(provider))
            }
            reset()
            return granted
        } catch {
            return false
        }
    }

    func reset() {
        // A fresh store observes authorization changes made in System Settings.
        store = EKEventStore()
    }

    var eventStore: EKEventStore { store }

    func containers(_ provider: ExternalProvider) -> [ExternalContainer] {
        store.calendars(for: type(provider))
            .map { ExternalContainer(id: $0.calendarIdentifier, title: $0.title, provider: provider) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func events(from start: Date, to end: Date, containerIDs: Set<String>) -> [ExternalItem] {
        let calendars = store.calendars(for: .event).filter { containerIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty, start < end else { return [] }
        var seen = Set<SourceKey>(), items: [ExternalItem] = []
        // EventKit limits predicate spans; query in one-year chunks.
        var chunkStart = start
        while chunkStart < end {
            let chunkEnd = min(end, chunkStart.addingTimeInterval(365 * 86_400))
            let predicate = store.predicateForEvents(withStart: chunkStart, end: chunkEnd, calendars: calendars)
            for event in store.events(matching: predicate) {
                let item = Self.item(event)
                // Occurrences spanning a chunk boundary are returned twice.
                if seen.insert(item.key).inserted { items.append(item) }
            }
            chunkStart = chunkEnd
        }
        return items
    }

    func reminders(containerIDs: Set<String>) async -> [ExternalItem] {
        let lists = store.calendars(for: .reminder).filter { containerIDs.contains($0.calendarIdentifier) }
        guard !lists.isEmpty else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        return reminders.map(Self.item)
    }

    func lookup(_ key: SourceKey, containerID: String) async -> ItemLookup {
        guard status(key.provider) == .fullAccess else { return .inaccessible }
        // A missing calendar/list may be an offline or removed account, so
        // only a missing item in an available container counts as deletion.
        let containerAvailable = store.calendar(withIdentifier: containerID) != nil
        if key.provider == .reminders {
            guard let reminder = store.calendarItem(withIdentifier: key.itemID) as? EKReminder else {
                return containerAvailable ? .deleted : .inaccessible
            }
            return .found(Self.item(reminder))
        }
        guard let master = store.calendarItem(withIdentifier: key.itemID) as? EKEvent else {
            return containerAvailable ? .deleted : .inaccessible
        }
        guard let occurrence = key.occurrence, master.hasRecurrenceRules else { return .found(Self.item(master)) }
        // Moved exceptions keep their original occurrence date.
        let predicate = store.predicateForEvents(
            withStart: occurrence.addingTimeInterval(-60 * 86_400), end: occurrence.addingTimeInterval(60 * 86_400),
            calendars: master.calendar.map { [$0] }
        )
        let match = store.events(matching: predicate).first {
            $0.calendarItemIdentifier == key.itemID && $0.occurrenceDate == occurrence
        }
        return match.map { .found(Self.item($0)) } ?? .deleted
    }

    func items(linking url: URL, provider: ExternalProvider, near date: Date) async -> [ExternalItem] {
        guard status(provider) == .fullAccess else { return [] }
        let candidates: [ExternalItem]
        if provider == .calendar {
            candidates = events(from: date.addingTimeInterval(-400 * 86_400), to: date.addingTimeInterval(400 * 86_400),
                                containerIDs: Set(store.calendars(for: .event).map(\.calendarIdentifier)))
        } else {
            let lists = store.calendars(for: .reminder)
            let predicate = store.predicateForReminders(in: lists)
            let reminders: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
            }
            candidates = reminders.map(Self.item)
        }
        return candidates.filter { $0.url == url }
    }

    func create(_ provider: ExternalProvider, _ draft: ExternalDraft) throws -> String {
        do {
            if provider == .calendar {
                guard let destination = store.defaultCalendarForNewEvents else { throw IntegrationFailure.noDestination(.calendar) }
                let item = EKEvent(eventStore: store)
                item.calendar = destination
                apply(draft, to: item)
                try store.save(item, span: .thisEvent, commit: true)
                return item.calendarItemIdentifier
            }
            guard let destination = store.defaultCalendarForNewReminders() else { throw IntegrationFailure.noDestination(.reminders) }
            let item = EKReminder(eventStore: store)
            item.calendar = destination
            apply(draft, to: item)
            try store.save(item, commit: true)
            return item.calendarItemIdentifier
        } catch let failure as IntegrationFailure {
            throw failure
        } catch {
            throw IntegrationFailure.system(error.localizedDescription)
        }
    }

    func update(_ provider: ExternalProvider, itemID: String, _ draft: ExternalDraft) throws {
        guard let item = store.calendarItem(withIdentifier: itemID) else { throw IntegrationFailure.itemMissing(provider) }
        do {
            if let event = item as? EKEvent {
                apply(draft, to: event)
                try store.save(event, span: .thisEvent, commit: true)
            } else if let reminder = item as? EKReminder {
                apply(draft, to: reminder)
                try store.save(reminder, commit: true)
            }
        } catch {
            throw IntegrationFailure.system(error.localizedDescription)
        }
    }

    private func apply(_ draft: ExternalDraft, to event: EKEvent) {
        event.title = draft.title
        event.startDate = draft.deadline
        event.endDate = draft.deadline.addingTimeInterval(30 * 60)
        event.timeZone = draft.timeZone
        event.url = draft.url
    }

    private func apply(_ draft: ExternalDraft, to reminder: EKReminder) {
        reminder.title = draft.title
        var components = EventTimeZone.calendar(in: draft.timeZone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: draft.deadline)
        components.timeZone = draft.timeZone
        reminder.dueDateComponents = components
        reminder.url = draft.url
    }

    private static func item(_ event: EKEvent) -> ExternalItem {
        let occurrence = event.hasRecurrenceRules ? event.occurrenceDate : nil
        return ExternalItem(
            key: SourceKey(provider: .calendar, itemID: event.calendarItemIdentifier, occurrence: occurrence),
            externalID: event.calendarItemExternalIdentifier,
            containerID: event.calendar?.calendarIdentifier ?? "",
            containerTitle: event.calendar?.title ?? "",
            title: event.title ?? "Untitled event",
            // All-day events start at local midnight of their calendar day.
            deadline: event.startDate,
            timeZoneIdentifier: event.isAllDay ? nil : event.timeZone?.identifier,
            isDateOnly: event.isAllDay,
            isCompleted: false,
            url: event.url
        )
    }

    private static func item(_ reminder: EKReminder) -> ExternalItem {
        let resolved = ReminderDue.resolve(reminder.dueDateComponents)
        return ExternalItem(
            key: SourceKey(provider: .reminders, itemID: reminder.calendarItemIdentifier, occurrence: nil),
            externalID: reminder.calendarItemExternalIdentifier,
            containerID: reminder.calendar?.calendarIdentifier ?? "",
            containerTitle: reminder.calendar?.title ?? "",
            title: reminder.title ?? "Untitled reminder",
            deadline: resolved?.date,
            timeZoneIdentifier: resolved?.zone,
            isDateOnly: resolved?.isDateOnly ?? false,
            isCompleted: reminder.isCompleted,
            url: reminder.url
        )
    }
}

enum ReminderDue {
    /// Date-only due dates count down to 23:59:59 on that day.
    static func resolve(_ components: DateComponents?) -> (date: Date, zone: String?, isDateOnly: Bool)? {
        guard var components, components.year != nil, components.month != nil, components.day != nil else { return nil }
        let zone = components.timeZone ?? .current
        let isDateOnly = components.hour == nil
        if isDateOnly {
            components.hour = 23
            components.minute = 59
            components.second = 59
        }
        components.second = components.second ?? 0
        components.minute = components.minute ?? 0
        var calendar = EventTimeZone.calendar(in: zone)
        calendar.timeZone = zone
        components.calendar = nil
        components.timeZone = nil
        guard let date = calendar.date(from: components) else { return nil }
        return (date, zone.identifier, isDateOnly)
    }
}
