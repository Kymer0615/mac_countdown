import AppIntents
import AppKit

struct CreateCountdownIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Countdown"
    static var description = IntentDescription("Create and pin an event with an exact deadline.")
    static var openAppWhenRun: Bool = true
    @Parameter(title: "Event name") var name: String
    @Parameter(title: "Deadline") var deadline: Date
    @Parameter(title: "Add to Calendar", default: false) var addToCalendar: Bool
    @Parameter(title: "Add to Reminders", default: false) var addToReminders: Bool
    @Parameter(title: "Critical window in hours", default: 24) var criticalHours: Double
    static var parameterSummary: some ParameterSummary { Summary("Create \(\.$name) counting down to \(\.$deadline)") {
        \.$addToCalendar
        \.$addToReminders
        \.$criticalHours
    } }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CountdownIntentError.emptyName }
        guard let app = NSApp.delegate as? CountdownApp else { throw CountdownIntentError.appUnavailable }
        guard criticalHours.isFinite, (0.1...8760).contains(criticalHours) else { throw CountdownIntentError.invalidCriticalWindow }
        let result = await app.createCountdown(title: title, deadline: deadline, zone: TimeZone.current.identifier, criticalHours: criticalHours, calendar: addToCalendar, reminder: addToReminders)
        return .result(dialog: "\(result)")
    }
}

struct CountdownShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreateCountdownIntent(), phrases: ["Create a countdown in \(.applicationName)", "Add an event in \(.applicationName)"], shortTitle: "Create Countdown", systemImageName: "timer")
    }
}

private enum CountdownIntentError: Error, LocalizedError {
    case emptyName, appUnavailable, invalidCriticalWindow
    var errorDescription: String? {
        switch self {
        case .invalidCriticalWindow: return "Critical window must be between 0.1 and 8760 hours."
        case .emptyName: return "Enter a name for the event."
        case .appUnavailable: return "Open Countdown Menu Bar and try the shortcut again."
        }
    }
}
