import AppKit
import EventKit
import AppIntents

@main
struct AppFeatureChecks {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "countdown.ui-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CountdownSettings(defaults: defaults)
        precondition(settings.fontSize == 13 && settings.fontStyle == "System")
        settings.fontStyle = "Monospaced"
        settings.fontSize = 18
        let restoredSettings = CountdownSettings(defaults: defaults)
        precondition(restoredSettings.fontSize == 18 && restoredSettings.fontStyle == "Monospaced")
        precondition(restoredSettings.appKitFont.pointSize == 18)
        defaults.set("invalid", forKey: "countdown.fontStyle")
        defaults.set(100, forKey: "countdown.fontSize")
        let repaired = CountdownSettings(defaults: defaults)
        precondition(repaired.fontStyle == "System" && repaired.fontSize == 22)

        let original = CountdownEvent(title: "Editor check", date: Date().addingTimeInterval(60 * 86400), timeZoneIdentifier: "AoE", createdAt: Date().addingTimeInterval(-86400), criticalHours: 48)
        let editor = EventEditor()
        func field<T>(_ object: Any, _ name: String) -> T {
            Mirror(reflecting: object).children.first { $0.label == name }!.value as! T
        }
        let timer = Timer(timeInterval: 0.25, repeats: false) { _ in
            MainActor.assumeIsolated {
                let critical: NSTextField = field(editor, "criticalField")
                precondition(critical.doubleValue == 48)
                critical.stringValue = "72"
                let calendar: NSButton = field(editor, "calendarCheck")
                precondition(!calendar.isEnabled && calendar.state == .off)
                let alert: NSAlert = field(editor, "alert")
                alert.buttons[0].performClick(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let edited = editor.run(event: original, initialDate: original.date)!
        precondition(edited.createdAt == original.createdAt && edited.id == original.id)
        precondition(abs(edited.date.timeIntervalSince(original.date)) < 1)
        precondition(edited.criticalHours == 72 && edited.timeZoneIdentifier == "AoE")
        precondition(!editor.addToCalendar && !editor.addToReminders)

        // Exercise the same intent that Siri/Shortcuts invokes, in this executable's
        // own preference domain. Never touch the installed app's preferences.
        let previousEvents = UserDefaults.standard.object(forKey: "countdown.events")
        let previousSelection = UserDefaults.standard.object(forKey: "countdown.selectedEventID")
        defer {
            UserDefaults.standard.set(previousEvents, forKey: "countdown.events")
            UserDefaults.standard.set(previousSelection, forKey: "countdown.selectedEventID")
        }
        let delegate = CountdownApp()
        app.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let intent = CreateCountdownIntent()
        intent.name = "Shortcut test"
        intent.deadline = Date().addingTimeInterval(36000)
        intent.criticalHours = 4
        intent.addToCalendar = false
        intent.addToReminders = false
        let beforeCalendar = EKEventStore.authorizationStatus(for: .event)
        let beforeReminders = EKEventStore.authorizationStatus(for: .reminder)
        _ = try await intent.perform()
        let store: EventStore = field(delegate, "store")
        precondition(store.selectedEvent?.title == "Shortcut test")
        precondition(store.selectedEvent?.criticalHours == 4)
        precondition(EKEventStore.authorizationStatus(for: .event) == beforeCalendar)
        precondition(EKEventStore.authorizationStatus(for: .reminder) == beforeReminders)
        let count = store.events.count
        intent.name = "   "
        do { _ = try await intent.perform(); preconditionFailure("Empty names must fail") } catch {}
        intent.name = "Invalid threshold"
        intent.criticalHours = -1
        do { _ = try await intent.perform(); preconditionFailure("Negative thresholds must fail") } catch {}
        precondition(store.events.count == count)
        for window in app.windows where window.isVisible { window.orderOut(nil) }
        print("Font persistence, editor metadata, opt-in defaults, and App Intent creation/validation checks passed")
    }
}
