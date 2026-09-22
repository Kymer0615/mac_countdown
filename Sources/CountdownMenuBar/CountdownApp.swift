import AppKit
import WidgetKit

@MainActor
final class CountdownApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = EventStore()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private lazy var moonAnimator = MoonAnimator(button: statusItem.button)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.onEventsChanged = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetEventData.kind) }
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetEventData.kind)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        refresh()
        timer = Timer(timeInterval: 1, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        timer?.tolerance = 0.1
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "countdownmenubar" else { return }
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
        if let event = store.selectedEvent {
            let remaining = event.date.timeIntervalSince(now)
            statusItem.button?.title = "\(event.title) · \(CountdownFormat.compact(until: event.date, now: now))"
            statusItem.button?.toolTip = "\(event.title) — \(fullDate(event))"
            statusItem.button?.setAccessibilityLabel("\(event.title), \(CountdownFormat.remaining(until: event.date, now: now)). \(fullDate(event))")
            moonAnimator.update(progress: MoonProgress.value(remaining: remaining), completed: remaining <= 0)
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
        addAction("Add Event…", #selector(addEvent), key: "n")
        let edit = addAction("Edit Selected Event…", #selector(editEvent), key: "e")
        edit.isEnabled = store.selectedEvent != nil
        let delete = addAction("Delete Selected Event…", #selector(deleteEvent), key: "")
        delete.isEnabled = store.selectedEvent != nil
        menu.addItem(.separator())
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
        let editor = EventEditor()
        if let updatedEvent = editor.run(event: event, initialDate: initialDate) {
            store.save(updatedEvent)
            refresh()
        }
    }

    @objc private func deleteEvent() {
        guard let event = store.selectedEvent else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete \"\(event.title)\"?"
        alert.informativeText = "This event will be removed from your countdown list."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.deleteSelected()
            refresh()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func menuTitle(for event: CountdownEvent) -> String {
        let calendar = EventTimeZone.calendar(in: event.timeZone)
        let countdown = CountdownFormat.remaining(until: event.date, calendar: calendar)
        return "\(event.title)  ·  \(fullDate(event))  ·  \(countdown)"
    }

    private func fullDate(_ event: CountdownEvent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = EventTimeZone.calendar(in: event.timeZone)
        formatter.timeZone = event.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return "\(formatter.string(from: event.date)) \(EventTimeZone.label(event.timeZoneIdentifier, at: event.date))"
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
