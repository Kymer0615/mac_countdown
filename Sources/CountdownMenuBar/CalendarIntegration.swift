import AppKit
import Foundation

/// Shared permission state for setup, the editor, Sync, Settings, and App
/// Intents. macOS authorization is always the source of truth.
@MainActor
final class IntegrationAccess: ObservableObject {
    static let setupKey = "countdown.integrationSetupVersion"
    static let setupVersion = 1

    @Published private(set) var calendar: ServiceAccess
    @Published private(set) var reminders: ServiceAccess
    let adapter: EventKitAdapter
    private let defaults: UserDefaults

    init(adapter: EventKitAdapter, defaults: UserDefaults = .standard) {
        self.adapter = adapter
        self.defaults = defaults
        calendar = ServiceAccess(provider: .calendar, status: adapter.status(.calendar))
        reminders = ServiceAccess(provider: .reminders, status: adapter.status(.reminders))
    }

    func access(_ provider: ExternalProvider) -> ServiceAccess {
        provider == .calendar ? calendar : reminders
    }

    /// Call before every operation and when the app becomes active.
    @discardableResult
    func refresh() -> Bool {
        let newCalendar = ServiceAccess(provider: .calendar, status: adapter.status(.calendar))
        let newReminders = ServiceAccess(provider: .reminders, status: adapter.status(.reminders))
        guard newCalendar != calendar || newReminders != reminders else { return false }
        adapter.reset()
        calendar = newCalendar
        reminders = newReminders
        return true
    }

    /// Prompts only when macOS can still show a prompt; otherwise opens the
    /// matching Privacy & Security pane instead of repeating a denied request.
    func request(_ provider: ExternalProvider) async {
        refresh()
        if access(provider).canRequest {
            _ = await adapter.requestFullAccess(provider)
            refresh()
        } else if !access(provider).canRead {
            openSystemSettings(provider)
        }
    }

    func openSystemSettings(_ provider: ExternalProvider) {
        let pane = provider == .calendar ? "Privacy_Calendars" : "Privacy_Reminders"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// First interactive launch after installing or upgrading to 1.3.
    var needsSetup: Bool { defaults.integer(forKey: Self.setupKey) < Self.setupVersion }

    /// Requests each service in turn; denying one never skips the other.
    /// Completion is stored separately from authorization.
    func runSetup(confirm: () -> Bool) async {
        guard needsSetup else { return }
        defaults.set(Self.setupVersion, forKey: Self.setupKey)
        refresh()
        guard ExternalProvider.allCases.contains(where: { access($0).canRequest }), confirm() else { return }
        for provider in ExternalProvider.allCases where access(provider).canRequest {
            _ = await adapter.requestFullAccess(provider)
            refresh()
        }
    }
}

struct ExportOutcome: Equatable {
    let provider: ExternalProvider
    let succeeded: Bool
    let message: String
}

/// Explicit outgoing create/update actions. Successful identifiers are saved
/// immediately so retries never duplicate an item.
@MainActor
final class CalendarIntegration {
    let access: IntegrationAccess
    private let store: EventStore
    private var inFlight = Set<String>()

    init(access: IntegrationAccess, store: EventStore) {
        self.access = access
        self.store = store
    }

    private var adapter: EventKitAdapter { access.adapter }

    func draft(for event: CountdownEvent) -> ExternalDraft {
        ExternalDraft(title: event.title, deadline: event.date, timeZone: event.timeZone, url: WidgetEventData.eventURL(event))
    }

    func perform(eventID: UUID, create: [ExternalProvider], update: [ExternalProvider]) async -> [ExportOutcome] {
        var outcomes: [ExportOutcome] = []
        for provider in ExternalProvider.allCases {
            if create.contains(provider) { outcomes.append(await add(eventID, to: provider)) }
            else if update.contains(provider) { outcomes.append(await updateLinked(eventID, provider)) }
        }
        return outcomes
    }

    func add(_ id: UUID, to provider: ExternalProvider) async -> ExportOutcome {
        let lock = "\(id)|\(provider.rawValue)"
        guard inFlight.insert(lock).inserted else { return failure(provider, "An addition is already in progress.") }
        defer { inFlight.remove(lock) }
        access.refresh()
        guard access.access(provider).canCreate else { return failure(provider, IntegrationFailure.notAuthorized(provider)) }
        guard let event = store.event(id) else { return failure(provider, "The countdown no longer exists.") }
        if event.exportLink(provider) != nil {
            return ExportOutcome(provider: provider, succeeded: true, message: "\(provider.name): already linked; nothing new was created.")
        }
        // Recover items from v1.2 or an interrupted save before creating another.
        if access.access(provider).canRead {
            let existing = await adapter.items(linking: WidgetEventData.eventURL(event), provider: provider, near: event.date)
            if existing.count > 1 { return failure(provider, IntegrationFailure.ambiguous(provider)) }
            if let match = existing.first {
                store.update(id) { $0.setExportLink(ExportLink(itemID: match.key.itemID, fingerprint: "", exportedAt: Date()), for: provider) }
                return ExportOutcome(provider: provider, succeeded: true, message: "\(provider.name): linked the existing item for this countdown instead of creating a duplicate.")
            }
        }
        do {
            let itemID = try adapter.create(provider, draft(for: event))
            store.update(id) { $0.setExportLink(ExportLink(itemID: itemID, fingerprint: event.exportFingerprint, exportedAt: Date()), for: provider) }
            let what = provider == .calendar ? "Added a 30-minute Calendar event at the deadline." : "Added a reminder due at the deadline."
            return ExportOutcome(provider: provider, succeeded: true, message: what)
        } catch {
            return failure(provider, error)
        }
    }

    func updateLinked(_ id: UUID, _ provider: ExternalProvider) async -> ExportOutcome {
        let lock = "\(id)|\(provider.rawValue)"
        guard inFlight.insert(lock).inserted else { return failure(provider, "An update is already in progress.") }
        defer { inFlight.remove(lock) }
        access.refresh()
        guard let event = store.event(id), let link = event.exportLink(provider) else {
            return failure(provider, "This countdown has no linked \(provider.name) item.")
        }
        guard access.access(provider).canRead else {
            return failure(provider, "Updating an existing \(provider.name) item requires full access. Allow it in Events & Settings → Settings.")
        }
        do {
            try adapter.update(provider, itemID: link.itemID, draft(for: event))
            store.update(id) { $0.setExportLink(ExportLink(itemID: link.itemID, fingerprint: event.exportFingerprint, exportedAt: Date()), for: provider) }
            return ExportOutcome(provider: provider, succeeded: true, message: "\(provider.name): updated the linked item.")
        } catch IntegrationFailure.itemMissing(let provider) {
            store.update(id) { $0.setExportLink(nil, for: provider) }
            return failure(provider, "The linked item was deleted in \(provider.name), so the link was removed. Choose Add to create a new one.")
        } catch {
            return failure(provider, error)
        }
    }

    private func failure(_ provider: ExternalProvider, _ error: Error) -> ExportOutcome {
        failure(provider, error.localizedDescription)
    }

    private func failure(_ provider: ExternalProvider, _ message: String) -> ExportOutcome {
        ExportOutcome(provider: provider, succeeded: false, message: "\(provider.name) was not changed: \(message)")
    }

    /// Opens a synchronized source item in Calendar or Reminders.
    static func openSource(_ link: SourceLink) {
        let raw = link.key.provider == .calendar
            ? "ical://ekevent/\(link.key.itemID)?method=show&options=more"
            : "x-apple-reminderkit://REMCDReminder/\(link.key.itemID)"
        let fallback = URL(fileURLWithPath: link.key.provider == .calendar ? "/System/Applications/Calendar.app" : "/System/Applications/Reminders.app")
        guard let url = URL(string: raw), NSWorkspace.shared.open(url) else {
            NSWorkspace.shared.open(fallback)
            return
        }
    }
}
