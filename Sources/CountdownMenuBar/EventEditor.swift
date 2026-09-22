import AppKit

@MainActor
final class EventEditor: NSObject, NSComboBoxDataSource, NSComboBoxDelegate {
    private let alert = NSAlert()
    private let titleField = NSTextField()
    private let datePicker = NSDatePicker()
    private let zoneBox = NSComboBox()
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let localIdentifier = TimeZone.current.identifier
    private var allZones: [String] = []
    private var filteredZones: [String] = []

    override init() {
        super.init()
        allZones = ["Local — \(localIdentifier)", "UTC", "AoE (UTC−12)"]
            + TimeZone.knownTimeZoneIdentifiers.filter { $0 != "UTC" }.sorted()
        filteredZones = allZones
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        titleField.placeholderString = "Event name"
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        datePicker.calendar = EventTimeZone.calendar(in: EventTimeZone.utc)
        datePicker.timeZone = EventTimeZone.utc
        datePicker.locale = Locale.current
        datePicker.target = self
        datePicker.action = #selector(dateChanged)

        zoneBox.usesDataSource = true
        zoneBox.dataSource = self
        zoneBox.delegate = self
        zoneBox.isEditable = true
        zoneBox.numberOfVisibleItems = 12
        zoneBox.placeholderString = "Search city, region, UTC, or AoE"
        zoneBox.toolTip = "Type to filter, then choose a zone. Changing zones keeps the entered clock time."
        preview.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        preview.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name"), titleField],
            [NSTextField(labelWithString: "Date and time"), datePicker],
            [NSTextField(labelWithString: "Time zone"), zoneBox]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 165))
        container.addSubview(grid)
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            zoneBox.widthAnchor.constraint(equalTo: titleField.widthAnchor),
            preview.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        alert.accessoryView = container
        alert.window.initialFirstResponder = titleField
    }

    func run(event: CountdownEvent?, initialDate: Date) -> CountdownEvent? {
        NSApp.activate(ignoringOtherApps: true)
        alert.messageText = event == nil ? "Add Event" : "Edit Event"
        alert.informativeText = "Enter the deadline in its time zone. Changing zones keeps the entered clock time."
        titleField.stringValue = event?.title ?? ""
        let identifier = event?.timeZoneIdentifier ?? localIdentifier
        zoneBox.stringValue = event == nil ? allZones[0] : (identifier == EventTimeZone.aoeIdentifier ? "AoE (UTC−12)" : identifier)
        datePicker.dateValue = EventTimeZone.pickerDate(
            for: initialDate, in: EventTimeZone.resolve(identifier) ?? .current
        )
        updatePreview()

        while alert.runModal() == .alertFirstButtonReturn {
            alert.window.makeFirstResponder(nil)
            let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                showError("Enter a name for the event.")
                continue
            }
            guard let identifier = selectedIdentifier,
                  let zone = EventTimeZone.resolve(identifier) else {
                showError("Choose a valid time zone from the list.")
                continue
            }
            guard let resolution = EventTimeZone.interpret(pickerDate: datePicker.dateValue, in: zone) else {
                showError("This local time does not exist because the clocks change. Choose a different time.")
                continue
            }
            return CountdownEvent(
                id: event?.id ?? UUID(), title: title, date: resolution.date,
                timeZoneIdentifier: identifier
            )
        }
        return nil
    }

    private var selectedIdentifier: String? {
        let value = zoneBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == allZones[0] || value.lowercased() == "local" { return localIdentifier }
        if value.lowercased() == "utc" { return "UTC" }
        if ["aoe", "aoe (utc−12)", "aoe (utc-12)"].contains(value.lowercased()) { return EventTimeZone.aoeIdentifier }
        return TimeZone.knownTimeZoneIdentifiers.first { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    private func showError(_ message: String) {
        preview.stringValue = message
        preview.textColor = .systemRed
    }

    @objc private func dateChanged() { updatePreview() }

    private func updatePreview() {
        guard let identifier = selectedIdentifier, let zone = EventTimeZone.resolve(identifier) else {
            showError("Type to filter, then choose a time zone from the list.")
            return
        }
        guard let resolution = EventTimeZone.interpret(pickerDate: datePicker.dateValue, in: zone) else {
            showError("This local time does not exist because the clocks change. Choose a different time.")
            return
        }
        preview.textColor = .secondaryLabelColor
        let formatter = DateFormatter()
        formatter.calendar = EventTimeZone.calendar(in: EventTimeZone.utc)
        formatter.timeZone = EventTimeZone.utc
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let offset = EventTimeZone.offsetLabel(for: zone, at: resolution.date)
        let note = resolution.isAmbiguous ? "This time occurs twice; the first occurrence is used. " : ""
        preview.stringValue = "\(note)\(offset) · \(formatter.string(from: resolution.date)) UTC"
    }

    func numberOfItems(in comboBox: NSComboBox) -> Int { filteredZones.count }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        filteredZones[index]
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        filteredZones = allZones
        zoneBox.reloadData()
    }

    func controlTextDidChange(_ notification: Notification) {
        let query = zoneBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredZones = query.isEmpty ? allZones : allZones.filter { $0.localizedCaseInsensitiveContains(query) }
        zoneBox.reloadData()
        updatePreview()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        let index = zoneBox.indexOfSelectedItem
        guard filteredZones.indices.contains(index) else { return }
        zoneBox.stringValue = filteredZones[index]
        updatePreview()
    }
}
