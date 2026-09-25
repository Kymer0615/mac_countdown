import AppKit
import EventKit
import AppIntents
import SwiftUI
import Vision

/// In-memory EventKit stand-in: tests never prompt for or touch personal data.
@MainActor
final class MockEventKit: EventKitAdapter {
    var statuses: [ExternalProvider: AccessStatus] = [.calendar: .notDetermined, .reminders: .notDetermined]
    var grantOnRequest: [ExternalProvider: AccessStatus] = [:]
    var requests: [ExternalProvider] = []
    var items: [ExternalItem] = []
    var inaccessibleContainers = Set<String>()
    var created: [(ExternalProvider, ExternalDraft)] = []
    var updated: [(ExternalProvider, String, ExternalDraft)] = []
    var failCreate: [ExternalProvider: IntegrationFailure] = [:]
    var queries = 0
    let containerList = [ExternalContainer(id: "work", title: "Work", provider: .calendar),
                         ExternalContainer(id: "home", title: "Home", provider: .calendar),
                         ExternalContainer(id: "todo", title: "To Do", provider: .reminders)]

    func status(_ provider: ExternalProvider) -> AccessStatus { statuses[provider] ?? .unknown }
    func requestFullAccess(_ provider: ExternalProvider) async -> Bool {
        requests.append(provider)
        statuses[provider] = grantOnRequest[provider] ?? .denied
        return statuses[provider] == .fullAccess
    }
    func containers(_ provider: ExternalProvider) -> [ExternalContainer] { containerList.filter { $0.provider == provider } }
    func events(from start: Date, to end: Date, containerIDs: Set<String>) -> [ExternalItem] {
        queries += 1
        return items.filter { $0.key.provider == .calendar && containerIDs.contains($0.containerID) && $0.deadline.map { $0 >= start && $0 < end } == true }
    }
    func reminders(containerIDs: Set<String>) async -> [ExternalItem] {
        queries += 1
        return items.filter { $0.key.provider == .reminders && containerIDs.contains($0.containerID) && !$0.isCompleted }
    }
    func lookup(_ key: SourceKey, containerID: String) async -> ItemLookup {
        guard status(key.provider) == .fullAccess, !inaccessibleContainers.contains(containerID) else { return .inaccessible }
        return items.first { $0.key == key }.map(ItemLookup.found) ?? .deleted
    }
    func items(linking url: URL, provider: ExternalProvider, near date: Date) async -> [ExternalItem] {
        items.filter { $0.key.provider == provider && $0.url == url }
    }
    func create(_ provider: ExternalProvider, _ draft: ExternalDraft) throws -> String {
        if let failure = failCreate[provider] { throw failure }
        created.append((provider, draft))
        let id = "created-\(created.count)"
        items.append(MockEventKit.item(provider, id, draft.title, draft.deadline, url: draft.url))
        return id
    }
    func update(_ provider: ExternalProvider, itemID: String, _ draft: ExternalDraft) throws {
        guard items.contains(where: { $0.key.itemID == itemID }) else { throw IntegrationFailure.itemMissing(provider) }
        updated.append((provider, itemID, draft))
    }
    func reset() {}

    static func item(_ provider: ExternalProvider, _ id: String, _ title: String, _ deadline: Date?, occurrence: Date? = nil,
                     container: String? = nil, dateOnly: Bool = false, completed: Bool = false, url: URL? = nil) -> ExternalItem {
        ExternalItem(key: SourceKey(provider: provider, itemID: id, occurrence: occurrence), externalID: "ext-\(id)",
                     containerID: container ?? (provider == .calendar ? "work" : "todo"), containerTitle: "Test",
                     title: title, deadline: deadline, timeZoneIdentifier: provider == .calendar && !dateOnly ? "UTC" : nil,
                     isDateOnly: dateOnly, isCompleted: completed, url: url)
    }
}

@main
struct AppFeatureChecks {
    @MainActor static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        func isolated() -> UserDefaults {
            let suite = "countdown.ui-tests.\(UUID().uuidString)"
            return UserDefaults(suiteName: suite)!
        }
        let defaults = isolated()
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
        print("Font persistence checks passed")

        try await permissionChecks(isolated)
        try await editorChecks(isolated)
        try await exportChecks(isolated)
        try await syncChecks(isolated)
        try await intentChecks()
        for window in app.windows where window.isVisible { window.orderOut(nil) }
    }

    // MARK: Permissions

    @MainActor static func permissionChecks(_ isolated: () -> UserDefaults) async throws {
        let writeOnly = ServiceAccess(provider: .calendar, status: .writeOnly)
        precondition(writeOnly.canCreate && !writeOnly.canRead && writeOnly.canRequest)
        precondition(!ServiceAccess(provider: .reminders, status: .writeOnly).canCreate)
        for status in [AccessStatus.denied, .restricted, .notDetermined, .unknown] {
            for provider in ExternalProvider.allCases {
                let state = ServiceAccess(provider: provider, status: status)
                precondition(!state.canCreate && !state.canRead, "\(status) must not grant access")
            }
        }
        precondition(ServiceAccess(provider: .reminders, status: .fullAccess).canRead)
        precondition(!ServiceAccess(provider: .calendar, status: .denied).canRequest, "Denied prompts are not repeated")

        // Denying Calendar does not skip Reminders; setup runs once.
        let mock = MockEventKit()
        mock.grantOnRequest = [.calendar: .denied, .reminders: .fullAccess]
        let defaults = isolated()
        let coordinator = IntegrationAccess(adapter: mock, defaults: defaults)
        precondition(coordinator.needsSetup)
        await coordinator.runSetup(confirm: { true })
        precondition(mock.requests == [.calendar, .reminders])
        precondition(coordinator.calendar.status == .denied && coordinator.reminders.canRead)
        precondition(!coordinator.needsSetup)
        await coordinator.runSetup(confirm: { preconditionFailure("Setup must not repeat") })
        precondition(mock.requests.count == 2)

        // Upgrading from write-only Calendar requests full access once.
        let upgrade = MockEventKit()
        upgrade.statuses = [.calendar: .writeOnly, .reminders: .fullAccess]
        upgrade.grantOnRequest = [.calendar: .fullAccess]
        let upgradeAccess = IntegrationAccess(adapter: upgrade, defaults: isolated())
        await upgradeAccess.runSetup(confirm: { true })
        precondition(upgrade.requests == [.calendar] && upgradeAccess.calendar.canRead)

        // Declining the explanation completes setup without prompting.
        let declined = MockEventKit()
        let declinedAccess = IntegrationAccess(adapter: declined, defaults: isolated())
        await declinedAccess.runSetup(confirm: { false })
        precondition(declined.requests.isEmpty && !declinedAccess.needsSetup)

        // Status changes made in System Settings are observed on refresh.
        declined.statuses[.reminders] = .fullAccess
        precondition(declinedAccess.refresh() && declinedAccess.reminders.canRead)
        declined.statuses[.reminders] = .denied
        precondition(declinedAccess.refresh() && !declinedAccess.reminders.canCreate)
        // A request that returns without a decision is reported, not silent.
        let silent = MockEventKit()
        silent.grantOnRequest = [.calendar: .notDetermined]
        let silentAccess = IntegrationAccess(adapter: silent, defaults: isolated())
        await silentAccess.request(.calendar)
        precondition(silent.requests == [.calendar] && silentAccess.requestProblem[.calendar] != nil)
        silent.grantOnRequest = [.calendar: .fullAccess]
        await silentAccess.request(.calendar)
        precondition(silentAccess.requestProblem[.calendar] == nil && silentAccess.calendar.canRead)
        print("Permission matrix, sequential setup, upgrade, revocation, and silent-request checks passed")
    }

    // MARK: Editor

    @MainActor static func editorChecks(_ isolated: () -> UserDefaults) async throws {
        let full = (ServiceAccess(provider: .calendar, status: .fullAccess), ServiceAccess(provider: .reminders, status: .fullAccess))
        let now = Date()
        let original = CountdownEvent(title: "Editor check", date: now.addingTimeInterval(60 * 86400).rounded(), timeZoneIdentifier: "AoE",
                                      createdAt: now.addingTimeInterval(-86400), startDate: now.addingTimeInterval(-3600).rounded(), critical: .unit(.hours, 48))
        let model = EventEditorModel(event: original, initialDate: original.date, calendar: full.0, reminders: full.1)
        precondition(model.criticalMode == .unit(.hours) && model.criticalValue == "48")
        precondition(model.offersCreate(.calendar) && model.offersCreate(.reminders), "Edit offers both authorized destinations")
        precondition(!model.addToCalendar && !model.addToReminders, "Additions are off by default")
        guard case .success(let unchanged) = model.validate() else { preconditionFailure("Unchanged event validates") }
        precondition(unchanged.event == original, "Exact-second round trip keeps every field")
        model.criticalMode = .unit(.days)
        model.criticalValue = "3"
        model.addToReminders = true
        guard case .success(let edited) = model.validate() else { preconditionFailure() }
        precondition(edited.event.createdAt == original.createdAt && edited.event.id == original.id)
        precondition(edited.event.critical == .unit(.days, 3) && edited.event.timeZoneIdentifier == "AoE")
        precondition(model.integrationRequest == EditorIntegrationRequest(create: [.reminders], update: []))

        // Invalid input reports an error and preserves the fields.
        model.startWall = model.deadlineWall.addingTimeInterval(60)
        guard case .failure(let startError) = model.validate() else { preconditionFailure("Start after deadline must fail") }
        precondition(startError.message.contains("start") && model.criticalValue == "3")
        model.startWall = EventTimeZone.pickerDate(for: original.startDate, in: original.timeZone)
        model.criticalMode = .unit(.months)
        model.criticalValue = "1.5"
        guard case .failure = model.validate() else { preconditionFailure("Fractional months must fail") }
        model.criticalMode = .custom
        (model.customMonths, model.customDays, model.customHours, model.customMinutes, model.customSeconds) = ("0", "1", "2", "3", "4")
        guard case .success(let customized) = model.validate() else { preconditionFailure() }
        precondition(customized.event.critical == .custom(months: 0, days: 1, hours: 2, minutes: 3, seconds: 4))
        model.criticalMode = .exact
        model.exactWall = model.deadlineWall
        guard case .failure = model.validate() else { preconditionFailure("Exact boundary must precede the deadline") }
        precondition(model.criticalPreview.contains("before the deadline"))
        model.exactWall = model.deadlineWall.addingTimeInterval(-7200)
        guard case .success(let exact) = model.validate() else { preconditionFailure() }
        precondition(exact.event.criticalBoundary == original.date.addingTimeInterval(-7200))

        // Day selection keeps the clock; the London spring-forward gap is rejected.
        let fresh = EventEditorModel(event: nil, initialDate: now.addingTimeInterval(86_400), calendar: full.0, reminders: full.1, now: now)
        precondition(fresh.criticalMode == .unit(.hours) && fresh.criticalValue == "24", "Default is 24 hours")
        fresh.title = "Gap"
        fresh.zoneText = "Europe/London"
        fresh.deadlineWall = ISO8601DateFormatter().date(from: "2031-03-30T01:30:00Z")!
        guard case .failure = fresh.validate() else { preconditionFailure("Nonexistent times are rejected") }

        // Permission combinations decide which destinations are shown.
        let none = EventEditorModel(event: nil, initialDate: now, calendar: ServiceAccess(provider: .calendar, status: .denied),
                                    reminders: ServiceAccess(provider: .reminders, status: .notDetermined))
        precondition(!none.showsIntegrationGroup)
        let remindersOnly = EventEditorModel(event: nil, initialDate: now, calendar: ServiceAccess(provider: .calendar, status: .denied), reminders: full.1)
        precondition(remindersOnly.showsIntegrationGroup && !remindersOnly.offersCreate(.calendar) && remindersOnly.offersCreate(.reminders))
        let writeOnly = EventEditorModel(event: nil, initialDate: now, calendar: ServiceAccess(provider: .calendar, status: .writeOnly),
                                         reminders: ServiceAccess(provider: .reminders, status: .denied))
        precondition(writeOnly.offersCreate(.calendar) && !writeOnly.offersCreate(.reminders))
        remindersOnly.addToReminders = true
        remindersOnly.updateAccess(calendar: full.0, reminders: ServiceAccess(provider: .reminders, status: .denied))
        precondition(!remindersOnly.addToReminders && remindersOnly.integrationRequest.create.isEmpty, "Revocation clears requests")

        // Linked exports show linked status instead of another create option.
        var linked = original
        linked.calendarExport = ExportLink(itemID: "c1", fingerprint: original.exportFingerprint, exportedAt: now)
        let linkedModel = EventEditorModel(event: linked, initialDate: linked.date, calendar: full.0, reminders: full.1)
        precondition(linkedModel.isLinked(.calendar) && !linkedModel.offersCreate(.calendar) && linkedModel.offersCreate(.reminders))
        linkedModel.addToCalendar = true
        linkedModel.updateCalendar = true
        precondition(linkedModel.integrationRequest == EditorIntegrationRequest(create: [], update: [.calendar]))

        // Synced sources lock title/deadline/zone until detached.
        var sourced = original
        sourced.source = SourceLink(key: SourceKey(provider: .calendar, itemID: "s1"), containerID: "work", externalID: nil,
                                    isDateOnly: false, completed: false, status: .current, lastSynced: now)
        let sourcedModel = EventEditorModel(event: sourced, initialDate: sourced.date, calendar: full.0, reminders: full.1)
        sourcedModel.title = "Changed locally"
        precondition(sourcedModel.sourceLocked)
        guard case .success(let kept) = sourcedModel.validate() else { preconditionFailure() }
        precondition(kept.event.title == "Editor check" && kept.event.source != nil)
        sourcedModel.detachSource = true
        guard case .success(let detached) = sourcedModel.validate() else { preconditionFailure() }
        precondition(detached.event.title == "Changed locally" && detached.event.source == nil)
        print("Editor model, validation, units, permission-driven options, and linked-state checks passed")

        // Initial rendering, before any click, at both appearances and font extremes.
        for (appearance, fontSize) in [(NSAppearance.Name.aqua, 10.0), (.darkAqua, 22.0), (.aqua, 13.0)] {
            let defaults = isolated()
            let mock = MockEventKit()
            mock.statuses = [.calendar: .fullAccess, .reminders: .fullAccess]
            let access = IntegrationAccess(adapter: mock, defaults: defaults)
            let settings = CountdownSettings(defaults: defaults)
            settings.fontSize = fontSize
            var saved = false
            let window = EventEditorWindow(event: original, initialDate: original.date, access: access, settings: settings,
                                           openSettings: {}, onSave: { _, _ in saved = true; return [] }, onClose: { _ in })
            window.window.appearance = NSAppearance(named: appearance)
            window.window.setContentSize(window.window.minSize)
            window.window.orderFrontRegardless()
            spin(0.6)
            let labels = try renderedTexts(window.window)
            for required in ["Also create", "Add to Calendar (30-minute event at the deadline)", "Add to Reminders (due at the deadline)", "Deadline", "Start", "Critical window", "Time zone", "Save", "Cancel"] {
                precondition(labels.contains { $0.contains(required) }, "\(required) must render on first display (\(appearance.rawValue), \(fontSize) pt); found \(labels)")
            }
            if appearance == .darkAqua {
                try snapshot(window.window, "editor-dark-22pt")
            } else if fontSize == 13 {
                try snapshot(window.window, "editor-light-13pt")
            }
            window.close()
            precondition(!saved, "Cancel/close never saves")
        }
        // No authorized destinations: the group is replaced by a settings link.
        let deniedDefaults = isolated()
        let denied = MockEventKit()
        denied.statuses = [.calendar: .denied, .reminders: .denied]
        let deniedWindow = EventEditorWindow(event: nil, initialDate: now.addingTimeInterval(86_400), access: IntegrationAccess(adapter: denied, defaults: deniedDefaults),
                                             settings: CountdownSettings(defaults: deniedDefaults), openSettings: {}, onSave: { _, _ in [] }, onClose: { _ in })
        deniedWindow.window.orderFrontRegardless()
        spin(0.5)
        let deniedLabels = try renderedTexts(deniedWindow.window)
        precondition(!deniedLabels.contains { $0.contains("Add to Calendar") || $0.contains("Add to Reminders") })
        precondition(deniedLabels.contains { $0.contains("Integration Settings") })
        deniedWindow.close()
        print("Editor initial rendering (light/dark, 10/13/22 pt, minimum size) and denied-state hiding checks passed")
    }

    /// Lets AppKit/SwiftUI lay out and draw before inspecting a window.
    static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    @MainActor static var captureCount = 0

    /// Text actually drawn in the window: the whole scrollable form plus the
    /// footer, recognized from pixels so clipped or invisible labels fail.
    @MainActor static func renderedTexts(_ window: NSWindow) throws -> [String] {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        func recognize(_ view: NSView) throws -> [String] {
            // Render at 2x so small captions are recognized reliably.
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0) else { return [] }
            bitmap.size = view.bounds.size
            // The window background is not part of the content view; paint it
            // first so text over transparent areas has real contrast.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: view.bounds.size).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            captureCount += 1
            try? FileManager.default.createDirectory(atPath: ".build/checks/evidence", withIntermediateDirectories: true)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: ".build/checks/evidence/capture-\(captureCount).png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
            var found = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            // Isolated one-word button titles are recognized more reliably alone.
            let footerHeight = 70 * 2
            if let footer = bitmap.cgImage!.cropping(to: CGRect(x: 0, y: bitmap.pixelsHigh - footerHeight, width: bitmap.pixelsWide, height: footerHeight)) {
                let footerRequest = VNRecognizeTextRequest()
                footerRequest.recognitionLevel = .fast
                try VNImageRequestHandler(cgImage: footer).perform([footerRequest])
                found += (footerRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            }
            return found
        }
        // First display, before any scrolling or clicks.
        var texts = try recognize(window.contentView!)
        // Then page through the lazily built form to prove every row is reachable.
        if let scroll = find(window.contentView!), let document = scroll.documentView {
            let page = max(40, scroll.contentView.bounds.height - 40)
            var y: CGFloat = 0
            while y < document.frame.height {
                y += page
                document.scroll(NSPoint(x: 0, y: min(y, max(0, document.frame.height - scroll.contentView.bounds.height))))
                spin(0.25)
                texts += try recognize(window.contentView!)
            }
            document.scroll(.zero)
        }
        return texts
    }

    @MainActor static func snapshot(_ window: NSWindow, _ name: String) throws {
        let view = window.contentView!
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: ".build/checks/evidence", withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: ".build/checks/evidence/\(name).png"))
    }

    // MARK: Exports

    @MainActor static func exportChecks(_ isolated: () -> UserDefaults) async throws {
        let defaults = isolated()
        let mock = MockEventKit()
        mock.statuses = [.calendar: .denied, .reminders: .fullAccess]
        let store = EventStore(defaults: defaults)
        let access = IntegrationAccess(adapter: mock, defaults: defaults)
        let integration = CalendarIntegration(access: access, store: store)
        let event = CountdownEvent(title: "Export", date: Date().addingTimeInterval(86_400).rounded())
        store.save(event)

        // Partial success: the countdown stays saved and the success is linked.
        let first = await integration.perform(eventID: event.id, create: [.calendar, .reminders], update: [])
        precondition(first.map(\.succeeded) == [false, true])
        precondition(first[0].message.contains("not changed"))
        precondition(store.event(event.id)?.reminderExport != nil && store.event(event.id)?.calendarExport == nil)
        precondition(mock.created.count == 1 && mock.created[0].1.url == WidgetEventData.eventURL(event))

        // Retrying only repeats the failed service; the reminder is not duplicated.
        mock.statuses[.calendar] = .writeOnly
        let retry = await integration.perform(eventID: event.id, create: [.calendar, .reminders], update: [])
        precondition(retry.allSatisfy(\.succeeded))
        precondition(mock.created.map(\.0) == [.reminders, .calendar])
        precondition(store.event(event.id)?.calendarExport?.itemID == "created-2")

        // Explicit update writes the local edits; write-only cannot update.
        store.update(event.id) { $0.title = "Export renamed" }
        let blocked = await integration.updateLinked(event.id, .calendar)
        precondition(!blocked.succeeded && mock.updated.isEmpty)
        mock.statuses[.calendar] = .fullAccess
        let updated = await integration.updateLinked(event.id, .calendar)
        precondition(updated.succeeded && mock.updated.count == 1 && mock.updated[0].2.title == "Export renamed")
        precondition(store.event(event.id)?.calendarExport?.fingerprint == store.event(event.id)?.exportFingerprint)

        // An externally deleted item removes the link instead of failing forever.
        mock.items.removeAll { $0.key.itemID == "created-1" }
        let missing = await integration.updateLinked(event.id, .reminders)
        precondition(!missing.succeeded && store.event(event.id)?.reminderExport == nil)

        // Items from v1.2 or an interrupted save are linked, not duplicated.
        let legacy = CountdownEvent(title: "Legacy export", date: Date().addingTimeInterval(7200))
        store.save(legacy)
        mock.items.append(MockEventKit.item(.calendar, "old", "Legacy export", legacy.date, url: WidgetEventData.eventURL(legacy)))
        let recovered = await integration.add(legacy.id, to: .calendar)
        precondition(recovered.succeeded && store.event(legacy.id)?.calendarExport?.itemID == "old" && mock.created.count == 2)
        mock.items.append(MockEventKit.item(.reminders, "dup1", "Legacy export", legacy.date, url: WidgetEventData.eventURL(legacy)))
        mock.items.append(MockEventKit.item(.reminders, "dup2", "Legacy export", legacy.date, url: WidgetEventData.eventURL(legacy)))
        let ambiguous = await integration.add(legacy.id, to: .reminders)
        precondition(!ambiguous.succeeded && mock.created.count == 2, "Ambiguous matches need the user's choice")

        // Missing default destination and no requested work.
        mock.failCreate[.reminders] = .noDestination(.reminders)
        let plain = CountdownEvent(title: "Plain", date: Date().addingTimeInterval(3600))
        store.save(plain)
        let noDestination = await integration.add(plain.id, to: .reminders)
        precondition(!noDestination.succeeded && store.event(plain.id) != nil)
        let nothing = await integration.perform(eventID: plain.id, create: [], update: [])
        precondition(nothing.isEmpty)
        precondition(mock.created.count == 2, "Unselected options never write")
        print("Export creation, partial failure, duplicate-safe retry, recovery, and explicit update checks passed")
    }

    // MARK: Sync

    @MainActor static func syncChecks(_ isolated: () -> UserDefaults) async throws {
        let defaults = isolated()
        let mock = MockEventKit()
        mock.statuses = [.calendar: .fullAccess, .reminders: .fullAccess]
        let store = EventStore(defaults: defaults)
        let access = IntegrationAccess(adapter: mock, defaults: defaults)
        let sync = CalendarSync(access: access, store: store, defaults: defaults)
        let now = Date()
        sync.now = { now }
        let pinned = CountdownEvent(title: "Pinned local", date: now.addingTimeInterval(9 * 86_400))
        store.save(pinned)
        let exported = CountdownEvent(title: "Exported", date: now.addingTimeInterval(4 * 86_400))
        store.save(exported)
        store.select(pinned.id)
        let series = now.addingTimeInterval(2 * 86_400)
        mock.items = [
            MockEventKit.item(.calendar, "meeting", "Meeting", now.addingTimeInterval(86_400)),
            MockEventKit.item(.calendar, "weekly", "Weekly", series, occurrence: series),
            MockEventKit.item(.calendar, "weekly", "Weekly", series.addingTimeInterval(7 * 86_400), occurrence: series.addingTimeInterval(7 * 86_400)),
            MockEventKit.item(.calendar, "far", "Far", now.addingTimeInterval(400 * 86_400)),
            MockEventKit.item(.calendar, "home1", "Home", now.addingTimeInterval(3 * 86_400), container: "home"),
            MockEventKit.item(.calendar, "export", "Exported", exported.date, url: WidgetEventData.eventURL(exported)),
            MockEventKit.item(.reminders, "undated", "Undated", nil),
        ]
        let components = DateComponents(year: 2031, month: 5, day: 6)
        let dateOnly = ReminderDue.resolve(components)!
        precondition(dateOnly.isDateOnly)
        let local = EventTimeZone.calendar(in: .current).dateComponents([.hour, .minute, .second], from: dateOnly.date)
        precondition(local.hour == 23 && local.minute == 59 && local.second == 59, "Date-only reminders count to 23:59:59")
        precondition(ReminderDue.resolve(nil) == nil && ReminderDue.resolve(DateComponents(year: 2031)) == nil)
        mock.items.append(MockEventKit.item(.reminders, "task", "Task", dateOnly.date, dateOnly: true))

        // Permission alone never imports.
        await sync.syncActive()
        precondition(store.events.count == 2 && mock.queries == 0)

        // Selected items only.
        sync.reloadContainers()
        await sync.reloadCandidates(.calendar)
        let calendarItems = sync.candidates[.calendar]!
        precondition(!calendarItems.contains { $0.title == "Far" }, "Default range is one year")
        precondition(sync.ineligibility(calendarItems.first { $0.title == "Exported" }!) == "Created by this app")
        var notifications = 0
        store.onEventsChanged = { notifications += 1 }
        await sync.activateSelected(.calendar, items: calendarItems.filter { $0.title == "Meeting" })
        precondition(notifications == 1, "One batch write")
        precondition(store.events.count == 3 && store.selectedID == pinned.id, "Imports never change the pin")
        let meeting = store.events.first { $0.title == "Meeting" }!
        precondition(meeting.date == now.addingTimeInterval(86_400) && meeting.startDate == now && meeting.source?.key.itemID == "meeting")
        precondition(meeting.critical == .default)

        // All matching: recurring occurrences stay distinct; exports are associated, not re-imported.
        sync.settings.calendar.containerIDs = ["work"]
        await sync.activateAll(.calendar)
        let titles = store.events.map(\.title).sorted()
        precondition(titles == ["Exported", "Meeting", "Pinned local", "Weekly", "Weekly"], "\(titles)")
        precondition(store.event(exported.id)?.calendarExport?.itemID == "export", "Export linked back to its countdown")
        await sync.syncActive()
        precondition(store.events.count == 5, "Repeated sync does not duplicate")

        // New matching items are discovered; source edits update owned fields only.
        mock.items.append(MockEventKit.item(.calendar, "new", "New item", now.addingTimeInterval(5 * 86_400)))
        let meetingIndex = mock.items.firstIndex { $0.key.itemID == "meeting" }!
        mock.items[meetingIndex] = MockEventKit.item(.calendar, "meeting", "Meeting moved", now.addingTimeInterval(6 * 86_400))
        var localMeeting = store.events.first { $0.source?.key.itemID == "meeting" }!
        localMeeting.critical = .unit(.days, 2)
        localMeeting.startDate = now.addingTimeInterval(3600)
        store.update(localMeeting.id) { $0 = localMeeting }
        await sync.syncActive()
        let moved = store.event(localMeeting.id)!
        precondition(moved.title == "Meeting moved" && moved.date == now.addingTimeInterval(6 * 86_400))
        precondition(moved.critical == .unit(.days, 2) && moved.startDate == now.addingTimeInterval(3600) && moved.id == meeting.id)
        precondition(store.events.contains { $0.title == "New item" })

        // A source moved before the start keeps the start and is flagged.
        mock.items[meetingIndex] = MockEventKit.item(.calendar, "meeting", "Meeting moved", now.addingTimeInterval(1800))
        await sync.syncActive()
        precondition(store.event(localMeeting.id)!.needsStartCorrection && store.event(localMeeting.id)!.startDate == now.addingTimeInterval(3600))

        // Deletion vs. inaccessibility: countdowns are kept either way.
        mock.items.removeAll { $0.key.itemID == "meeting" }
        await sync.syncActive()
        precondition(store.event(localMeeting.id)?.source?.status == .missing)
        mock.inaccessibleContainers = ["work"]
        mock.items.removeAll { $0.key.itemID == "new" }
        await sync.syncActive()
        let newItem = store.events.first { $0.title == "New item" }!
        precondition(newItem.source?.status == .inaccessible, "Unavailable accounts are not deletions")
        mock.inaccessibleContainers = []

        // Removing an imported countdown excludes it from "all matching".
        let weekly = store.events.first { $0.title == "Weekly" }!
        sync.recordRemoval(of: weekly)
        store.delete(weekly.id)
        await sync.syncActive()
        precondition(store.events.filter { $0.title == "Weekly" }.count == 1)
        sync.clearExclusions(.calendar)
        await sync.syncActive()
        precondition(store.events.filter { $0.title == "Weekly" }.count == 2)

        // Reminders: date-only deadline, undated items ineligible, completion and reopening.
        await sync.reloadCandidates(.reminders)
        let reminders = sync.candidates[.reminders]!
        precondition(sync.ineligibility(reminders.first { $0.title == "Undated" }!) == "No due date")
        await sync.activateSelected(.reminders, items: reminders)
        precondition(!store.events.contains { $0.title == "Undated" })
        let task = store.events.first { $0.title == "Task" }!
        precondition(task.date == dateOnly.date && task.source?.isDateOnly == true)
        let taskIndex = mock.items.firstIndex { $0.key.itemID == "task" }!
        mock.items[taskIndex] = MockEventKit.item(.reminders, "task", "Task", dateOnly.date, dateOnly: true, completed: true)
        await sync.syncActive()
        precondition(store.event(task.id)!.isCompleted(at: now) && store.event(task.id)!.date == dateOnly.date, "Completion keeps the deadline")
        mock.items[taskIndex] = MockEventKit.item(.reminders, "task", "Task", dateOnly.date, dateOnly: true, completed: false)
        await sync.syncActive()
        precondition(!store.event(task.id)!.isCompleted(at: now))

        // Overlapping requests are serialized and coalesced.
        mock.queries = 0
        async let a: Void = sync.syncActive()
        async let b: Void = sync.syncActive()
        async let c: Void = sync.syncActive()
        _ = await (a, b, c)
        precondition(!sync.isSyncing && mock.queries <= 4, "Coalesced overlapping syncs (\(mock.queries) queries)")

        // Revocation keeps last values and reports the problem.
        mock.statuses[.calendar] = .denied
        let before = store.events.count
        await sync.syncActive()
        precondition(store.events.count == before && sync.settings.calendar.lastError != nil)
        precondition(store.events.filter { $0.source?.key.provider == .calendar }.allSatisfy { $0.source?.status == .inaccessible })
        mock.statuses[.calendar] = .fullAccess

        // Settings persist; stopping detaches countdowns as local copies.
        let reloaded = CalendarSync(access: access, store: store, defaults: defaults)
        precondition(reloaded.settings == sync.settings)
        sync.stop(.calendar)
        precondition(sync.settings.calendar.mode == .off && store.events.count == before)
        precondition(!store.events.contains { $0.source?.key.provider == .calendar })
        precondition(store.events.contains { $0.source?.key.provider == .reminders })
        precondition(store.selectedID == pinned.id)
        print("Sync selection, all-matching discovery, recurrence, exclusions, completion, missing sources, coalescing, and stop checks passed")
    }

    // MARK: App Intents

    @MainActor static func intentChecks() async throws {
        // Exercise the same intent that Siri/Shortcuts invokes, in this executable's
        // own preference domain. Never touch the installed app's preferences.
        let previous = ["countdown.events", "countdown.selectedEventID", IntegrationAccess.setupKey].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in previous { UserDefaults.standard.set(value, forKey: key) } }
        let mock = MockEventKit()
        mock.statuses = [.calendar: .denied, .reminders: .fullAccess]
        let delegate = CountdownApp(defaults: .standard, adapter: mock, runsSetup: false)
        NSApplication.shared.delegate = delegate
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
        let store = Mirror(reflecting: delegate).children.first { $0.label == "store" }!.value as! EventStore
        precondition(store.selectedEvent?.title == "Shortcut test")
        precondition(store.selectedEvent?.critical == .unit(.hours, 4))
        precondition(EKEventStore.authorizationStatus(for: .event) == beforeCalendar)
        precondition(EKEventStore.authorizationStatus(for: .reminder) == beforeReminders)
        precondition(mock.requests.isEmpty && mock.created.isEmpty)

        // New parameters take precedence over the legacy hours value.
        intent.name = "Minutes"
        intent.criticalAmount = 90
        intent.criticalUnit = .minutes
        intent.start = Date().addingTimeInterval(600)
        _ = try await intent.perform()
        precondition(store.selectedEvent?.critical == .unit(.minutes, 90))
        precondition(abs(store.selectedEvent!.startDate.timeIntervalSince(intent.start!)) < 0.001)
        precondition(intent.criticalWindow == .unit(.minutes, 90))
        intent.criticalAmount = nil
        precondition(intent.criticalWindow == .unit(.hours, 4))

        let count = store.events.count
        intent.name = "   "
        do { _ = try await intent.perform(); preconditionFailure("Empty names must fail") } catch {}
        intent.name = "Invalid threshold"
        intent.criticalHours = -1
        do { _ = try await intent.perform(); preconditionFailure("Negative thresholds must fail") } catch {}
        intent.criticalHours = 24
        intent.start = intent.deadline.addingTimeInterval(1)
        do { _ = try await intent.perform(); preconditionFailure("Start after deadline must fail") } catch {}
        precondition(store.events.count == count)
        intent.criticalHours = 10_000
        intent.start = nil
        intent.name = "Long window"
        _ = try await intent.perform()
        precondition(store.events.count == count + 1, "No 8760-hour limit")

        // A denied requested addition is reported, not claimed as success.
        let result = await delegate.createCountdown(title: "Partial", deadline: Date().addingTimeInterval(7200), zone: "UTC", start: nil,
                                                    critical: .default, calendar: true, reminder: true)
        guard case .success(let message) = result else { preconditionFailure() }
        precondition(message.contains("Calendar was not changed") && message.contains("Added a reminder"), message)
        precondition(store.events.contains { $0.title == "Partial" && $0.reminderExport != nil && $0.calendarExport == nil })
        print("App Intent creation, legacy/new parameter precedence, validation, and honest partial-result checks passed")
    }
}

private extension Date {
    func rounded() -> Date { Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate.rounded()) }
}
