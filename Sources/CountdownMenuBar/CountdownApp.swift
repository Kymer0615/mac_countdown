import AppKit
import WidgetKit

@MainActor
final class CountdownApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store: EventStore
    private let settings: CountdownSettings
    private let access: IntegrationAccess
    private let integration: CalendarIntegration
    private let sync: CalendarSync
    private let runsSetup: Bool
    private lazy var management = ManagementWindow(
        store: store, settings: settings, access: access, sync: sync,
        add: { [weak self] in self?.addEvent() },
        edit: { [weak self] event in self?.presentEditor(event: event, initialDate: event.date) },
        delete: { [weak self] event in self?.remove(event) }
    )
    private var editors: [EventEditorWindow] = []
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private lazy var moonAnimator = MoonAnimator(button: statusItem.button)

    /// Tests and documentation renderers inject an adapter and skip the
    /// interactive permission setup so they never prompt.
    init(defaults: UserDefaults = .standard, adapter: EventKitAdapter? = nil, runsSetup: Bool = true) {
        store = EventStore(defaults: defaults)
        settings = CountdownSettings(defaults: defaults)
        access = IntegrationAccess(adapter: adapter ?? LiveEventKitAdapter(), defaults: defaults)
        integration = CalendarIntegration(access: access, store: store)
        sync = CalendarSync(access: access, store: store, defaults: defaults)
        self.runsSetup = runsSetup
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.onEventsChanged = { [weak self] in
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetEventData.kind)
            self?.refresh()
        }
        settings.onChange = { [weak self] in self?.refresh() }
        CountdownShortcuts.updateAppShortcutParameters()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetEventData.kind)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        refresh()
        timer = Timer(timeInterval: 1, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        timer?.tolerance = 0.1
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.access.refresh() }
        }
        sync.startObservingChanges()
        Task {
            if runsSetup && access.needsSetup {
                await access.runSetup(confirm: Self.confirmIntegrationSetup)
            }
            await sync.syncActive()
        }
    }

    private static func confirmIntegrationSetup() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Connect Calendar and Reminders?"
        alert.informativeText = "Countdown Menu Bar can add countdowns to Calendar and Reminders and sync items you choose into countdowns. macOS will ask for each separately; you can decline either one. Local countdowns work without access, and you can change this later in Events & Settings → Settings."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "countdownmenubar" else { return }
        if url.host == "settings" { management.show(.settings); return }
        if url.host == "sync" { management.show(.sync); return }
        if url.host == "about" { management.show(.about); return }
        if url.host == "manage" { showManagement(); return }
        if url.host == "add" {
            addEvent()
            return
        }
        if url.host == "event", let id = UUID(uuidString: url.lastPathComponent) {
            store.select(id)
            refresh()
        }
        statusItem.button?.performClick(nil)
    }

    @objc private func refresh() {
        let now = Date()
        statusItem.button?.font = settings.appKitFont
        if let event = store.selectedEvent {
            statusItem.button?.title = "\(event.title) · \(CountdownFormat.compact(for: event, now: now))"
            let starts = now < event.startDate ? "\nStarts \(format(event.startDate, event))" : ""
            statusItem.button?.toolTip = "\(event.title) — \(fullDate(event))\(starts)"
            statusItem.button?.setAccessibilityLabel("\(event.title), \(CountdownFormat.remaining(for: event, now: now)). \(fullDate(event))")
            moonAnimator.update(progress: MoonProgress.value(for: event, now: now), completed: event.isCompleted(at: now), urgency: MoonProgress.urgency(for: event, now: now))
        } else {
            moonAnimator.reset()
            statusItem.button?.title = "⏳ Add event"
            statusItem.button?.toolTip = "Click to add a countdown event"
            statusItem.button?.setAccessibilityLabel("Add countdown event")
        }
        updateEventMenuItems()
    }

    private func updateEventMenuItems() {
        for item in menu.items {
            guard let rawID = item.representedObject as? String,
                  let id = UUID(uuidString: rawID),
                  let event = store.events.first(where: { $0.id == id }) else { continue }
            item.title = menuTitle(for: event)
            item.state = event.id == store.selectedID ? .on : .off
        }
    }

    private func populateMenu() {
        menu.removeAllItems()
        let heading = NSMenuItem(title: "Events", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        if store.events.isEmpty {
            let empty = NSMenuItem(title: "No events yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for event in store.sortedEvents {
                let item = NSMenuItem(
                    title: menuTitle(for: event),
                    action: #selector(selectEvent(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = event.id.uuidString
                item.state = event.id == store.selectedID ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addAction("Events & Settings…", #selector(showManagement), key: ",")
        addAction("Add Event…", #selector(addEvent), key: "n")
        let edit = addAction("Edit Selected Event…", #selector(editEvent), key: "e")
        edit.isEnabled = store.selectedEvent != nil
        let delete = addAction("Delete Selected Event…", #selector(deleteEvent), key: "")
        delete.isEnabled = store.selectedEvent != nil
        menu.addItem(.separator())
        addAction("Sync Calendar and Reminders…", #selector(showSync), key: "")
        addAction("About Countdown Menu Bar", #selector(showAbout), key: "")
        addAction("Quit Countdown", #selector(quit), key: "q")
    }

    @discardableResult
    private func addAction(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func selectEvent(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID) else { return }
        store.select(id)
        refresh()
    }

    @objc private func addEvent() {
        let initialDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        presentEditor(event: nil, initialDate: initialDate)
    }

    @objc private func editEvent() {
        guard let event = store.selectedEvent else { return }
        presentEditor(event: event, initialDate: event.date)
    }

    private func presentEditor(event: CountdownEvent?, initialDate: Date) {
        // One editor per existing event; bring it forward instead of duplicating.
        if let event, let open = editors.first(where: { $0.model.original?.id == event.id }) {
            open.show()
            return
        }
        let editor = EventEditorWindow(
            event: event, initialDate: initialDate, access: access, settings: settings,
            openSettings: { [weak self] in self?.management.show(.settings) },
            onSave: { [weak self] event, request in
                guard let self else { return [] }
                return await self.commit(event, create: request.create, update: request.update)
            },
            onClose: { [weak self] editor in self?.editors.removeAll { $0 === editor } }
        )
        editors.append(editor)
        editor.show()
    }

    /// The single save path for the editor and App Intents: saves locally
    /// first, then performs only the requested external writes.
    func commit(_ event: CountdownEvent, create: [ExternalProvider], update: [ExternalProvider] = []) async -> [ExportOutcome] {
        store.save(event)
        refresh()
        return await integration.perform(eventID: event.id, create: create, update: update)
    }

    private func remove(_ event: CountdownEvent) {
        sync.recordRemoval(of: event)
        store.delete(event.id)
        refresh()
    }

    @objc private func deleteEvent() {
        guard let event = store.selectedEvent else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete \"\(event.title)\"?"
        alert.informativeText = "This event will be removed from your countdown list. Calendar and Reminders items are not deleted."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            remove(event)
        }
    }

    @objc private func showManagement() { management.show() }
    @objc private func showSync() { management.show(.sync) }
    @objc private func showAbout() { management.show(.about) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        management.show()
        return true
    }

    /// App Intents path. Requested additions for unavailable services are
    /// reported honestly rather than as success.
    func createCountdown(title: String, deadline: Date, zone: String, start: Date?, critical: CriticalWindow, calendar: Bool, reminder: Bool) async -> Result<String, CountdownIntentError> {
        let now = Date()
        let startDate = start ?? min(now, deadline.addingTimeInterval(-1))
        guard startDate < deadline else { return .failure(.startAfterDeadline) }
        let timeZone = EventTimeZone.resolve(zone) ?? .current
        if case .failure(let failure) = critical.resolve(deadline: deadline, zone: timeZone) {
            return .failure(.invalidCriticalWindow(failure.message))
        }
        let event = CountdownEvent(title: title, date: deadline, timeZoneIdentifier: zone, createdAt: now, startDate: startDate, critical: critical)
        let requested = [calendar ? ExternalProvider.calendar : nil, reminder ? .reminders : nil].compactMap { $0 }
        let outcomes = await commit(event, create: requested)
        management.show()
        var lines = ["Created \(title)."] + outcomes.map(\.message)
        if outcomes.contains(where: { !$0.succeeded }) {
            lines.append("Open Events & Settings → Settings to allow access, then edit the countdown to add it.")
        }
        return .success(lines.joined(separator: " "))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func menuTitle(for event: CountdownEvent) -> String {
        let countdown = CountdownFormat.remaining(for: event)
        return "\(event.title)  ·  \(fullDate(event))  ·  \(countdown)"
    }

    private func format(_ date: Date, _ event: CountdownEvent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = EventTimeZone.calendar(in: event.timeZone)
        formatter.timeZone = event.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func fullDate(_ event: CountdownEvent) -> String {
        "\(format(event.date, event)) \(EventTimeZone.label(event.timeZoneIdentifier, at: event.date))"
    }
}

@main
struct CountdownMenuBar {
    static func main() {
        let app = NSApplication.shared
        let delegate = CountdownApp()
        app.delegate = delegate
        app.run()
    }
}
