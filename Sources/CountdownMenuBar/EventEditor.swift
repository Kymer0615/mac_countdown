import AppKit
import SwiftUI

enum CriticalMode: Hashable, Identifiable, CaseIterable {
    case unit(CriticalUnit), custom, exact

    static var allCases: [CriticalMode] { CriticalUnit.allCases.map(CriticalMode.unit) + [.custom, .exact] }
    var id: String { label }
    var label: String {
        switch self {
        case .unit(let unit): return unit.label
        case .custom: return "Custom duration"
        case .exact: return "Exact date and time"
        }
    }
}

struct ValidationError: Error, Equatable, ExpressibleByStringInterpolation {
    let message: String
    init(_ message: String) { self.message = message }
    init(stringLiteral value: String) { message = value }
}

/// Requested external writes chosen in the editor.
struct EditorIntegrationRequest: Equatable {
    var create: [ExternalProvider] = []
    var update: [ExternalProvider] = []
}

/// Editor state and validation, shared by new and existing events. Dates are
/// held as wall-clock values in UTC pickers (see `EventTimeZone.pickerDate`).
@MainActor
final class EventEditorModel: ObservableObject {
    static let localPrefix = "Local — "
    let original: CountdownEvent?
    let localIdentifier = TimeZone.current.identifier

    @Published var title: String
    @Published var zoneText: String
    @Published var startWall: Date
    @Published var deadlineWall: Date
    @Published var criticalMode: CriticalMode = .unit(.hours)
    @Published var criticalValue = "24"
    @Published var customMonths = "0"
    @Published var customDays = "0"
    @Published var customHours = "24"
    @Published var customMinutes = "0"
    @Published var customSeconds = "0"
    @Published var exactWall: Date
    @Published var addToCalendar = false
    @Published var addToReminders = false
    @Published var updateCalendar = false
    @Published var updateReminders = false
    @Published var detachSource = false
    @Published var error: String?
    @Published var isSaving = false
    @Published private(set) var calendarAccess: ServiceAccess
    @Published private(set) var remindersAccess: ServiceAccess

    init(event: CountdownEvent?, initialDate: Date, calendar: ServiceAccess, reminders: ServiceAccess, now: Date = Date()) {
        original = event
        calendarAccess = calendar
        remindersAccess = reminders
        let identifier = event?.timeZoneIdentifier ?? TimeZone.current.identifier
        let zone = EventTimeZone.resolve(identifier) ?? .current
        title = event?.title ?? ""
        zoneText = event == nil ? Self.localPrefix + identifier : Self.zoneLabel(identifier)
        deadlineWall = EventTimeZone.pickerDate(for: event?.date ?? initialDate, in: zone)
        startWall = EventTimeZone.pickerDate(for: event?.startDate ?? now, in: zone)
        exactWall = EventTimeZone.pickerDate(for: (event?.date ?? initialDate).addingTimeInterval(-86_400), in: zone)
        switch event?.critical ?? .default {
        case .unit(let unit, let value):
            criticalMode = .unit(unit)
            criticalValue = value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .custom(let m, let d, let h, let min, let s):
            criticalMode = .custom
            (customMonths, customDays, customHours, customMinutes, customSeconds) = (String(m), String(d), String(h), String(min), String(s))
        case .exact(let date):
            criticalMode = .exact
            exactWall = EventTimeZone.pickerDate(for: date, in: zone)
        }
    }

    static func zoneLabel(_ identifier: String) -> String {
        identifier == EventTimeZone.aoeIdentifier ? "AoE (UTC−12)" : identifier
    }

    var allZones: [String] {
        [Self.localPrefix + localIdentifier, "UTC", "AoE (UTC−12)"] + TimeZone.knownTimeZoneIdentifiers.filter { $0 != "UTC" }.sorted()
    }

    func updateAccess(calendar: ServiceAccess, reminders: ServiceAccess) {
        calendarAccess = calendar
        remindersAccess = reminders
        // Revoked services cannot be requested.
        if !calendar.canCreate { addToCalendar = false }
        if !reminders.canCreate { addToReminders = false }
        if !calendar.canRead { updateCalendar = false }
        if !reminders.canRead { updateReminders = false }
    }

    func access(_ provider: ExternalProvider) -> ServiceAccess { provider == .calendar ? calendarAccess : remindersAccess }

    /// Title, deadline, and zone belong to a linked source until detached.
    var sourceLocked: Bool { original?.source != nil && !detachSource }

    func isLinked(_ provider: ExternalProvider) -> Bool { original?.exportLink(provider) != nil }

    /// Unlinked destinations the user is authorized to add to.
    func offersCreate(_ provider: ExternalProvider) -> Bool { !isLinked(provider) && access(provider).canCreate }

    var showsIntegrationGroup: Bool {
        ExternalProvider.allCases.contains { isLinked($0) || offersCreate($0) }
    }

    var selectedIdentifier: String? {
        let value = zoneText.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == Self.localPrefix + localIdentifier || value.lowercased() == "local" { return localIdentifier }
        if value.lowercased() == "utc" { return "UTC" }
        if ["aoe", "aoe (utc−12)", "aoe (utc-12)"].contains(value.lowercased()) { return EventTimeZone.aoeIdentifier }
        return TimeZone.knownTimeZoneIdentifiers.first { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    private static let nonexistent = "does not exist because the clocks change. Choose a different time."

    func criticalWindow(zone: TimeZone) -> Result<CriticalWindow, ValidationError> {
        switch criticalMode {
        case .unit(let unit):
            let text = criticalValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            guard let value = Double(text), value.isFinite, value > 0 else {
                return .failure("Enter a positive number for the critical window.")
            }
            if unit == .months && value != value.rounded() { return .failure("Months must be a whole number.") }
            return .success(.unit(unit, value))
        case .custom:
            let fields = [customMonths, customDays, customHours, customMinutes, customSeconds].map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard fields.allSatisfy({ ($0 ?? -1) >= 0 }) else { return .failure("Custom duration fields must be whole numbers of zero or more.") }
            let v = fields.map { $0! }
            return .success(.custom(months: v[0], days: v[1], hours: v[2], minutes: v[3], seconds: v[4]))
        case .exact:
            guard let resolution = EventTimeZone.interpret(pickerDate: exactWall, in: zone) else {
                return .failure("The critical time \(Self.nonexistent)")
            }
            return .success(.exact(resolution.date))
        }
    }

    struct Validated {
        let event: CountdownEvent
        let notes: [String]
    }

    /// Validates once and preserves every input when reporting an error.
    func validate(now: Date = Date()) -> Result<Validated, ValidationError> {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier: String, deadline: Date
        var notes: [String] = []
        if let original, sourceLocked {
            identifier = original.timeZoneIdentifier
            deadline = original.date
        } else {
            guard !trimmed.isEmpty else { return .failure("Enter a name for the event.") }
            guard let chosen = selectedIdentifier, let zone = EventTimeZone.resolve(chosen) else {
                return .failure("Choose a valid time zone from the list.")
            }
            guard let resolution = EventTimeZone.interpret(pickerDate: deadlineWall, in: zone) else {
                return .failure("This deadline \(Self.nonexistent)")
            }
            if resolution.isAmbiguous { notes.append("The deadline time occurs twice; the first occurrence is used.") }
            identifier = chosen
            deadline = resolution.date
        }
        let zone = EventTimeZone.resolve(identifier) ?? .current
        guard let start = EventTimeZone.interpret(pickerDate: startWall, in: zone) else {
            return .failure("This start time \(Self.nonexistent)")
        }
        if start.isAmbiguous { notes.append("The start time occurs twice; the first occurrence is used.") }
        guard start.date < deadline else { return .failure("The start must be before the deadline.") }
        let critical: CriticalWindow
        switch criticalWindow(zone: zone) {
        case .failure(let message): return .failure(message)
        case .success(let value): critical = value
        }
        switch critical.resolve(deadline: deadline, zone: zone) {
        case .failure(let failure): return .failure(ValidationError(failure.message))
        case .success(let boundary):
            if boundary.isAmbiguous { notes.append("The critical boundary time occurs twice; the first occurrence is used.") }
        }
        var event = original ?? CountdownEvent(title: trimmed, date: deadline, timeZoneIdentifier: identifier, createdAt: now)
        if !sourceLocked {
            event.title = trimmed
            event.date = deadline
            event.timeZoneIdentifier = identifier
        }
        if detachSource { event.source = nil }
        event.startDate = start.date
        event.critical = critical
        return .success(Validated(event: event, notes: notes))
    }

    var integrationRequest: EditorIntegrationRequest {
        var request = EditorIntegrationRequest()
        if addToCalendar && offersCreate(.calendar) { request.create.append(.calendar) }
        if addToReminders && offersCreate(.reminders) { request.create.append(.reminders) }
        if updateCalendar && isLinked(.calendar) && calendarAccess.canRead { request.update.append(.calendar) }
        if updateReminders && isLinked(.reminders) && remindersAccess.canRead { request.update.append(.reminders) }
        return request
    }

    // MARK: Previews

    private func utcString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = EventTimeZone.calendar(in: EventTimeZone.utc)
        formatter.timeZone = EventTimeZone.utc
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date) + " UTC"
    }

    private func localString(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = EventTimeZone.calendar(in: zone)
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private var previewZone: TimeZone? {
        if let original, sourceLocked { return original.timeZone }
        return selectedIdentifier.flatMap(EventTimeZone.resolve)
    }

    private var previewDeadline: Date? {
        if let original, sourceLocked { return original.date }
        return previewZone.flatMap { EventTimeZone.interpret(pickerDate: deadlineWall, in: $0)?.date }
    }

    var deadlinePreview: String {
        guard let zone = previewZone else { return "Type to filter, then choose a time zone from the list." }
        if let original, sourceLocked { return "\(EventTimeZone.offsetLabel(for: zone, at: original.date)) · \(utcString(original.date))" }
        guard let resolution = EventTimeZone.interpret(pickerDate: deadlineWall, in: zone) else { return "This deadline \(Self.nonexistent)" }
        let note = resolution.isAmbiguous ? "Occurs twice; the first occurrence is used. " : ""
        return "\(note)\(EventTimeZone.offsetLabel(for: zone, at: resolution.date)) · \(utcString(resolution.date))"
    }

    var startPreview: String {
        guard let zone = previewZone else { return "" }
        guard let resolution = EventTimeZone.interpret(pickerDate: startWall, in: zone) else { return "This start time \(Self.nonexistent)" }
        let note = resolution.isAmbiguous ? "Occurs twice; the first occurrence is used. " : ""
        return "\(note)\(EventTimeZone.offsetLabel(for: zone, at: resolution.date)) · \(utcString(resolution.date)). The moon stays full until the start."
    }

    var criticalPreview: String {
        guard let zone = previewZone, let deadline = previewDeadline else { return "Choose a valid deadline to see when the critical phase begins." }
        let window: CriticalWindow
        switch criticalWindow(zone: zone) {
        case .failure(let error): return error.message
        case .success(let value): window = value
        }
        switch window.resolve(deadline: deadline, zone: zone) {
        case .failure(let failure): return failure.message
        case .success(let boundary):
            var text = "Critical phase begins \(localString(boundary.date, zone)) (\(utcString(boundary.date)))."
            if boundary.isAmbiguous { text += " That clock time occurs twice; the first occurrence is used." }
            if let start = EventTimeZone.interpret(pickerDate: startWall, in: zone)?.date, boundary.date <= start {
                text += " This is before the start, so the event begins already in its critical phase."
            }
            return text
        }
    }
}

// MARK: - Window

@MainActor
final class EventEditorWindow: NSObject, NSWindowDelegate {
    typealias SaveHandler = (CountdownEvent, EditorIntegrationRequest) async -> [ExportOutcome]
    let model: EventEditorModel
    let window: NSWindow
    private let onSave: SaveHandler
    private let onClose: (EventEditorWindow) -> Void
    private let access: IntegrationAccess
    private var activeObserver: NSObjectProtocol?

    init(event: CountdownEvent?, initialDate: Date, access: IntegrationAccess, settings: CountdownSettings,
         openSettings: @escaping () -> Void, onSave: @escaping SaveHandler, onClose: @escaping (EventEditorWindow) -> Void) {
        access.refresh()
        self.access = access
        model = EventEditorModel(event: event, initialDate: initialDate, calendar: access.calendar, reminders: access.reminders)
        self.onSave = onSave
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = event == nil ? "Add Event" : "Edit Event"
        window.minSize = NSSize(width: 560, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: EventEditorView(
            model: model, settings: settings, save: { [weak self] in self?.save() }, cancel: { [weak self] in self?.close() },
            openSettings: openSettings
        ))
        if let visible = NSScreen.main?.visibleFrame {
            window.setContentSize(NSSize(width: min(620, visible.width - 40), height: min(640, visible.height - 40)))
        }
        window.center()
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func refreshAccess() {
        access.refresh()
        model.updateAccess(calendar: access.calendar, reminders: access.reminders)
    }

    func save() {
        guard !model.isSaving else { return }
        // Commit the active text field or date picker before validating.
        window.makeFirstResponder(nil)
        refreshAccess()
        switch model.validate() {
        case .failure(let error):
            model.error = error.message
        case .success(let validated):
            model.error = nil
            model.isSaving = true
            let request = model.integrationRequest
            Task {
                let outcomes = await onSave(validated.event, request)
                model.isSaving = false
                close()
                Self.report(outcomes: outcomes, notes: validated.notes)
            }
        }
    }

    static func report(outcomes: [ExportOutcome], notes: [String]) {
        guard !outcomes.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = outcomes.allSatisfy(\.succeeded) ? "Countdown saved" : "Countdown saved; some additions failed"
        let retry = outcomes.contains { !$0.succeeded } ? "\n\nSuccessful additions are linked. Edit the countdown to retry only the failed ones." : ""
        alert.informativeText = (outcomes.map(\.message) + notes).joined(separator: "\n") + retry
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        onClose(self)
    }
}

// MARK: - Views

private struct EventEditorView: View {
    @ObservedObject var model: EventEditorModel
    @ObservedObject var settings: CountdownSettings
    let save: () -> Void
    let cancel: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $model.title, prompt: Text("Event name"))
                        .disabled(model.sourceLocked)
                    if let source = model.original?.source, !model.detachSource {
                        LinkedSourceRow(source: source, detach: { model.detachSource = true })
                    }
                }
                Section {
                    WallClockField(label: "Date and time", date: $model.deadlineWall).disabled(model.sourceLocked)
                    LabeledContent("Time zone") {
                        ZoneField(text: $model.zoneText, zones: model.allZones).disabled(model.sourceLocked)
                    }
                    Text(model.deadlinePreview).font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Deadline")
                } footer: {
                    Text("Changing zones keeps the entered clock time.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Start") {
                    WallClockField(label: "Starts at", date: $model.startWall)
                    Text(model.startPreview).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Measure in", selection: $model.criticalMode) {
                        ForEach(CriticalMode.allCases) { Text($0.label).tag($0) }
                    }
                    criticalInputs
                    Text(model.criticalPreview).font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Critical window")
                } footer: {
                    Text("Hours, minutes, and seconds are elapsed time. Days and months are calendar days and months in the event’s zone, so 1 day and 24 hours can differ across daylight-saving changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                integrationSection
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 12) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(3)
                        .accessibilityLabel("Error: \(error)")
                }
                Spacer(minLength: 0)
                if model.isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(model.isSaving)
            }
            .padding(16)
        }
        .font(settings.swiftUIFont)
        .frame(minWidth: 560, minHeight: 480)
    }

    @ViewBuilder private var criticalInputs: some View {
        switch model.criticalMode {
        case .unit(let unit):
            LabeledContent("Amount") {
                HStack {
                    TextField("Amount", text: $model.criticalValue).labelsHidden().frame(maxWidth: 140)
                    Text(unit.label.lowercased()).foregroundStyle(.secondary)
                }
            }
        case .custom:
            LabeledContent("Duration") {
                HStack(spacing: 6) {
                    durationField("months", "mo", $model.customMonths)
                    durationField("days", "d", $model.customDays)
                    durationField("hours", "h", $model.customHours)
                    durationField("minutes", "m", $model.customMinutes)
                    durationField("seconds", "s", $model.customSeconds)
                }
            }
        case .exact:
            WallClockField(label: "Critical from", date: $model.exactWall)
        }
    }

    private func durationField(_ name: String, _ suffix: String, _ value: Binding<String>) -> some View {
        HStack(spacing: 2) {
            TextField(name, text: value).labelsHidden().frame(width: 52).accessibilityLabel(name)
            Text(suffix).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var integrationSection: some View {
        Section {
            if model.showsIntegrationGroup {
                ForEach(ExternalProvider.allCases) { provider in
                    integrationRow(provider)
                }
                Text("Linked items change only when you choose Update. Deleting or unlinking a countdown never deletes Calendar or Reminders items.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Calendar and Reminders are not connected.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Integration Settings…", action: openSettings)
                }
            }
        } header: {
            Text(model.showsIntegrationGroup ? "Also create" : "Calendar and Reminders")
        }
    }

    @ViewBuilder private func integrationRow(_ provider: ExternalProvider) -> some View {
        if let link = model.original?.exportLink(provider), let event = model.original {
            let current = link.fingerprint == event.exportFingerprint
            VStack(alignment: .leading, spacing: 4) {
                Label("Linked to \(provider.name)" + (current ? "" : " · local changes not sent"), systemImage: "link")
                if model.access(provider).canRead {
                    Toggle(provider == .calendar ? "Update linked Calendar event when saving" : "Update linked reminder when saving",
                           isOn: provider == .calendar ? $model.updateCalendar : $model.updateReminders)
                        .toggleStyle(.checkbox)
                } else {
                    Text("Updating the linked item requires full \(provider.name) access.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if model.offersCreate(provider) {
            Toggle(provider == .calendar ? "Add to Calendar (30-minute event at the deadline)" : "Add to Reminders (due at the deadline)",
                   isOn: provider == .calendar ? $model.addToCalendar : $model.addToReminders)
                .toggleStyle(.checkbox)
        }
    }
}

private struct LinkedSourceRow: View {
    let source: SourceLink
    let detach: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Synced from \(source.key.provider.name). Name and deadline follow the source.", systemImage: "arrow.triangle.2.circlepath")
            if source.status != .current {
                Text(source.status == .missing ? "The source item was deleted or moved; the last synced values are kept." : "The source is not accessible right now; the last synced values are kept.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Open Source") { CalendarIntegration.openSource(source) }
                Button("Detach to Edit Locally", action: detach)
            }
        }
    }
}

/// Keyboard-editable date and time to the second plus a month calendar
/// popover. Choosing a day keeps the clock time; editing the time keeps the day.
private struct WallClockField: View {
    let label: String
    @Binding var date: Date
    @State private var showsCalendar = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                WallClockPicker(date: $date, calendarStyle: false).fixedSize()
                Button { showsCalendar.toggle() } label: { Image(systemName: "calendar") }
                    .help("Choose a day")
                    .accessibilityLabel("Choose \(label.lowercased()) day")
                    .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                        WallClockPicker(date: Binding(get: { date }, set: { date = Self.combine(day: $0, time: date) }), calendarStyle: true)
                            .fixedSize().padding(10)
                    }
            }
        }
    }

    static func combine(day: Date, time: Date) -> Date {
        let calendar = EventTimeZone.calendar(in: EventTimeZone.utc)
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        let clock = calendar.dateComponents([.hour, .minute, .second], from: time)
        (parts.hour, parts.minute, parts.second) = (clock.hour, clock.minute, clock.second)
        return calendar.date(from: parts) ?? day
    }
}

private struct WallClockPicker: NSViewRepresentable {
    @Binding var date: Date
    let calendarStyle: Bool

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = calendarStyle ? .clockAndCalendar : .textFieldAndStepper
        picker.datePickerElements = calendarStyle ? [.yearMonthDay] : [.yearMonthDay, .hourMinuteSecond]
        picker.calendar = EventTimeZone.calendar(in: EventTimeZone.utc)
        picker.timeZone = EventTimeZone.utc
        picker.locale = Locale.current
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.dateValue = date
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        if picker.dateValue != date { picker.dateValue = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: WallClockPicker
        init(parent: WallClockPicker) { self.parent = parent }
        @objc func changed(_ sender: NSDatePicker) { parent.date = sender.dateValue }
    }
}

/// Searchable zone list: type to filter, then choose a result.
private struct ZoneField: NSViewRepresentable {
    @Binding var text: String
    let zones: [String]

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = true
        box.dataSource = context.coordinator
        box.delegate = context.coordinator
        box.isEditable = true
        box.numberOfVisibleItems = 12
        box.placeholderString = "Search city, region, UTC, or AoE"
        box.toolTip = "Type to filter, then choose a zone. Changing zones keeps the entered clock time."
        box.setAccessibilityLabel("Time zone")
        box.stringValue = text
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if box.stringValue != text && box.currentEditor() == nil { box.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSComboBoxDataSource, NSComboBoxDelegate {
        var parent: ZoneField
        var filtered: [String]
        init(parent: ZoneField) {
            self.parent = parent
            filtered = parent.zones
        }

        func numberOfItems(in comboBox: NSComboBox) -> Int { filtered.count }
        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? { filtered[index] }

        func controlTextDidBeginEditing(_ notification: Notification) {
            filtered = parent.zones
            (notification.object as? NSComboBox)?.reloadData()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            let query = box.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            filtered = query.isEmpty ? parent.zones : parent.zones.filter { $0.localizedCaseInsensitiveContains(query) }
            box.reloadData()
            parent.text = box.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox, filtered.indices.contains(box.indexOfSelectedItem) else { return }
            box.stringValue = filtered[box.indexOfSelectedItem]
            parent.text = box.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let box = notification.object as? NSComboBox { parent.text = box.stringValue }
        }
    }
}
