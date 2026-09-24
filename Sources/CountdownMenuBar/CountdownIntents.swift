import AppIntents
import AppKit

enum CriticalUnitOption: String, AppEnum {
    case seconds, minutes, hours, days, months

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Critical window unit"
    static var caseDisplayRepresentations: [CriticalUnitOption: DisplayRepresentation] = [
        .seconds: "Seconds", .minutes: "Minutes", .hours: "Hours", .days: "Days", .months: "Months"
    ]

    var unit: CriticalUnit { CriticalUnit(rawValue: rawValue)! }
}

struct CreateCountdownIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Countdown"
    static var description = IntentDescription("Create and pin an event with an exact deadline. A critical window amount, when given, overrides the older hours setting.")
    static var openAppWhenRun: Bool = true
    @Parameter(title: "Event name") var name: String
    @Parameter(title: "Deadline") var deadline: Date
    @Parameter(title: "Add to Calendar", default: false) var addToCalendar: Bool
    @Parameter(title: "Add to Reminders", default: false) var addToReminders: Bool
    /// Kept for shortcuts saved with version 1.2.
    @Parameter(title: "Critical window in hours", default: 24) var criticalHours: Double
    @Parameter(title: "Start") var start: Date?
    @Parameter(title: "Critical window amount") var criticalAmount: Double?
    @Parameter(title: "Critical window unit", default: .hours) var criticalUnit: CriticalUnitOption
    static var parameterSummary: some ParameterSummary { Summary("Create \(\.$name) counting down to \(\.$deadline)") {
        \.$addToCalendar
        \.$addToReminders
        \.$start
        \.$criticalAmount
        \.$criticalUnit
        \.$criticalHours
    } }

    /// An explicit amount overrides the legacy hours parameter.
    var criticalWindow: CriticalWindow {
        if let criticalAmount { return .unit(criticalUnit.unit, criticalAmount) }
        return .unit(.hours, criticalHours)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CountdownIntentError.emptyName }
        guard let app = NSApp.delegate as? CountdownApp else { throw CountdownIntentError.appUnavailable }
        let result = await app.createCountdown(
            title: title, deadline: deadline, zone: TimeZone.current.identifier, start: start,
            critical: criticalWindow, calendar: addToCalendar, reminder: addToReminders
        )
        switch result {
        case .success(let message): return .result(dialog: "\(message)")
        case .failure(let error): throw error
        }
    }
}

struct CountdownShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreateCountdownIntent(), phrases: ["Create a countdown in \(.applicationName)", "Add an event in \(.applicationName)"], shortTitle: "Create Countdown", systemImageName: "timer")
    }
}

enum CountdownIntentError: Error, LocalizedError {
    case emptyName, appUnavailable, invalidCriticalWindow(String), startAfterDeadline
    var errorDescription: String? {
        switch self {
        case .invalidCriticalWindow(let message): return message
        case .startAfterDeadline: return "The start must be before the deadline."
        case .emptyName: return "Enter a name for the event."
        case .appUnavailable: return "Open Countdown Menu Bar and try the shortcut again."
        }
    }
}
