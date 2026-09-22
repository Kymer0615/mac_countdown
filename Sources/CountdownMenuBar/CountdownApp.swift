import AppKit

@MainActor
final class CountdownApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = EventStore()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.1
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu()
    }

    private func refresh() {
        if let event = store.selectedEvent {
            statusItem.button?.title = "⏳ \(event.title): \(CountdownFormat.remaining(until: event.date))"
            statusItem.button?.toolTip = "\(event.title) — \(fullDate(event.date))"
        } else {
            statusItem.button?.title = "⏳ Add event"
            statusItem.button?.toolTip = "Click to add a countdown event"
        }
        updateEventMenuItems()
    }

    private func updateEventMenuItems() {
        for item in menu.items {
            guard let rawID = item.representedObject as? String,
                  let id = UUID(uuidString: rawID),
                  let event = store.events.first(where: { $0.id == id }) else { continue }
            let countdown = CountdownFormat.remaining(until: event.date)
            item.title = "\(event.title)  ·  \(fullDate(event.date))  ·  \(countdown)"
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
                let countdown = CountdownFormat.remaining(until: event.date)
                let item = NSMenuItem(
                    title: "\(event.title)  ·  \(fullDate(event.date))  ·  \(countdown)",
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
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = event == nil ? "Add Event" : "Edit Event"
        alert.informativeText = "Choose a name and an exact local date and time."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let titleLabel = NSTextField(labelWithString: "Name")
        let titleField = NSTextField(string: event?.title ?? "")
        titleField.placeholderString = "Event name"
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let dateLabel = NSTextField(labelWithString: "Date and time")
        let datePicker = NSDatePicker()
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        datePicker.dateValue = initialDate
        datePicker.locale = Locale.current
        datePicker.timeZone = TimeZone.current

        let grid = NSGridView(views: [
            [titleLabel, titleField],
            [dateLabel, datePicker]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 90))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 270)
        ])
        alert.accessoryView = container
        alert.window.initialFirstResponder = titleField

        while alert.runModal() == .alertFirstButtonReturn {
            let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                store.save(CountdownEvent(id: event?.id ?? UUID(), title: title, date: datePicker.dateValue))
                refresh()
                return
            }
            alert.informativeText = "Enter a name for the event."
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

    private func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
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
