import EventKit
import Foundation

/// Only writes items explicitly requested while creating a countdown.
@MainActor
final class CalendarIntegration {
    private let store = EKEventStore()

    func add(_ event: CountdownEvent, calendar: Bool, reminder: Bool) async -> [String] {
        var results: [String] = []
        if calendar {
            do {
                let allowed: Bool
                if #available(macOS 14, *) { allowed = try await store.requestWriteOnlyAccessToEvents() }
                else { allowed = try await store.requestAccess(to: .event) }
                guard allowed else { throw IntegrationError.denied("Calendar") }
                guard let destination = store.defaultCalendarForNewEvents else { throw IntegrationError.noCalendar("Calendar") }
                let item = EKEvent(eventStore: store)
                item.title = event.title
                item.startDate = event.date
                item.endDate = event.date.addingTimeInterval(30 * 60)
                item.timeZone = event.timeZone
                item.calendar = destination
                item.url = WidgetEventData.eventURL(event)
                try store.save(item, span: .thisEvent)
                results.append("Added a 30-minute Calendar event at the deadline.")
            } catch { results.append("Calendar was not added: \(error.localizedDescription)") }
        }
        if reminder {
            do {
                let allowed: Bool
                if #available(macOS 14, *) { allowed = try await store.requestFullAccessToReminders() }
                else { allowed = try await store.requestAccess(to: .reminder) }
                guard allowed else { throw IntegrationError.denied("Reminders") }
                guard let destination = store.defaultCalendarForNewReminders() else { throw IntegrationError.noCalendar("Reminders") }
                let item = EKReminder(eventStore: store)
                item.title = event.title
                item.calendar = destination
                var components = EventTimeZone.calendar(in: event.timeZone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: event.date)
                components.timeZone = event.timeZone
                item.dueDateComponents = components
                item.url = WidgetEventData.eventURL(event)
                try store.save(item, commit: true)
                results.append("Added a reminder due at the deadline.")
            } catch { results.append("Reminder was not added: \(error.localizedDescription)") }
        }
        return results
    }
}

private enum IntegrationError: LocalizedError {
    case denied(String), noCalendar(String)
    var errorDescription: String? {
        switch self {
        case .denied(let name): return "Allow \(name) access in System Settings → Privacy & Security. Your countdown is saved."
        case .noCalendar(let name): return "Set up a default list in \(name) first. Your countdown is saved."
        }
    }
}
