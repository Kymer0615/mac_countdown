import EventKit
import Foundation

enum SyncMode: String, Codable {
    case off, selected, allMatching
}

struct SelectedSource: Codable, Hashable {
    var key: SourceKey
    var containerID: String
}

struct ProviderSyncConfig: Codable, Equatable {
    var mode: SyncMode = .off
    /// nil means every calendar or list.
    var containerIDs: [String]?
    /// nil start means today; nil end means one year after the start.
    var rangeStart: Date?
    var rangeEnd: Date?
    var search = ""
    var selected: [SelectedSource] = []
    var exclusions: [SourceKey] = []
    var lastSuccess: Date?
    var lastError: String?
}

struct SyncSettings: Codable, Equatable {
    var calendar = ProviderSyncConfig()
    var reminders = ProviderSyncConfig()

    subscript(provider: ExternalProvider) -> ProviderSyncConfig {
        get { provider == .calendar ? calendar : reminders }
        set { if provider == .calendar { calendar = newValue } else { reminders = newValue } }
    }
}

/// One-way incoming synchronization from Calendar/Reminders to countdowns.
/// Runs on launch, on Sync now, and after debounced store-change
/// notifications while the app is running. Nothing is imported until the
/// user makes a selection and activates sync.
@MainActor
final class CalendarSync: ObservableObject {
    static let settingsKey = "countdown.sync"

    @Published var settings: SyncSettings { didSet { persist() } }
    @Published private(set) var isSyncing = false
    @Published private(set) var candidates: [ExternalProvider: [ExternalItem]] = [:]
    @Published private(set) var containers: [ExternalProvider: [ExternalContainer]] = [:]

    let access: IntegrationAccess
    private let store: EventStore
    private let defaults: UserDefaults
    private var pending = Set<ExternalProvider>()
    private var debounce: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    var now: () -> Date = Date.init

    init(access: IntegrationAccess, store: EventStore, defaults: UserDefaults = .standard) {
        self.access = access
        self.store = store
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey), let saved = try? JSONDecoder().decode(SyncSettings.self, from: data) {
            settings = saved
        } else {
            settings = SyncSettings()
        }
    }

    func startObservingChanges() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
    }

    /// Coalesces bursts of store notifications into one sync.
    func scheduleSync(delay: TimeInterval = 1.5) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.syncActive()
        }
    }

    var isActive: Bool { ExternalProvider.allCases.contains { settings[$0].mode != .off } }

    func syncActive() async {
        await sync(ExternalProvider.allCases.filter { settings[$0].mode != .off })
    }

    /// Serialized: overlapping requests are queued and run once afterwards.
    func sync(_ providers: [ExternalProvider]) async {
        pending.formUnion(providers)
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        while let provider = ExternalProvider.allCases.first(where: pending.contains) {
            pending.remove(provider)
            await performSync(provider)
        }
    }

    // MARK: Discovery

    func range(for config: ProviderSyncConfig) -> (Date, Date) {
        let start = config.rangeStart ?? Calendar.current.startOfDay(for: now())
        let end = config.rangeEnd ?? Calendar.current.date(byAdding: .year, value: 1, to: start) ?? start.addingTimeInterval(365 * 86_400)
        return (start, max(start, end))
    }

    func selectedContainerIDs(_ provider: ExternalProvider) -> Set<String> {
        let all = Set((containers[provider] ?? access.adapter.containers(provider)).map(\.id))
        guard let chosen = settings[provider].containerIDs else { return all }
        return Set(chosen).intersection(all)
    }

    func reloadContainers() {
        access.refresh()
        for provider in ExternalProvider.allCases {
            containers[provider] = access.access(provider).canRead ? access.adapter.containers(provider) : []
            if !access.access(provider).canRead { candidates[provider] = [] }
        }
    }

    /// Items in the selected sources and range, filtered by search.
    func query(_ provider: ExternalProvider) async -> [ExternalItem] {
        guard access.access(provider).canRead else { return [] }
        let config = settings[provider]
        let ids = selectedContainerIDs(provider)
        let items: [ExternalItem]
        if provider == .calendar {
            let (start, end) = range(for: config)
            items = access.adapter.events(from: start, to: end, containerIDs: ids)
        } else {
            items = await access.adapter.reminders(containerIDs: ids)
        }
        let search = config.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return items
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
            .sorted { ($0.deadline ?? .distantFuture, $0.title) < ($1.deadline ?? .distantFuture, $1.title) }
    }

    func reloadCandidates(_ provider: ExternalProvider) async {
        access.refresh()
        if containers[provider] == nil { reloadContainers() }
        candidates[provider] = await query(provider)
    }

    /// Why an item cannot become a synchronized countdown, if any.
    func ineligibility(_ item: ExternalItem) -> String? {
        if item.deadline == nil { return "No due date" }
        if item.isCompleted { return "Completed" }
        if let id = countdownID(linkedBy: item), store.event(id) != nil { return "Created by this app" }
        if store.events.contains(where: { $0.source?.key == item.key }) { return "Already synced" }
        if settings[item.key.provider].exclusions.contains(item.key) { return "Removed earlier" }
        return nil
    }

    private func countdownID(linkedBy item: ExternalItem) -> UUID? {
        guard let url = item.url, url.scheme == "countdownmenubar", url.host == "event" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    // MARK: Subscriptions

    func activateSelected(_ provider: ExternalProvider, items: [ExternalItem]) async {
        var config = settings[provider]
        let chosen = items.filter { ineligibility($0) == nil || ineligibility($0) == "Removed earlier" }
        // Choosing an excluded item again is an explicit request to follow it.
        config.exclusions.removeAll { key in chosen.contains { $0.key == key } }
        let existing = Set(config.selected.map(\.key))
        config.selected += chosen.filter { !existing.contains($0.key) }.map { SelectedSource(key: $0.key, containerID: $0.containerID) }
        if config.mode != .allMatching { config.mode = .selected }
        settings[provider] = config
        await sync([provider])
        await reloadCandidates(provider)
    }

    func activateAll(_ provider: ExternalProvider) async {
        settings[provider].mode = .allMatching
        await sync([provider])
        await reloadCandidates(provider)
    }

    /// Stops following sources. Countdowns remain as local copies with their
    /// last known values; system permissions and source items are unchanged.
    func stop(_ provider: ExternalProvider) {
        var config = settings[provider]
        config.mode = .off
        config.selected = []
        settings[provider] = config
        let detached = store.events.filter { $0.source?.key.provider == provider }.map { event -> CountdownEvent in
            var copy = event
            copy.source = nil
            return copy
        }
        store.apply(upserts: detached)
    }

    /// Prevents an active subscription from recreating a removed countdown.
    func recordRemoval(of event: CountdownEvent) {
        guard let source = event.source, settings[source.key.provider].mode != .off else { return }
        var config = settings[source.key.provider]
        if !config.exclusions.contains(source.key) { config.exclusions.append(source.key) }
        config.selected.removeAll { $0.key == source.key }
        settings[source.key.provider] = config
    }

    func clearExclusions(_ provider: ExternalProvider) {
        settings[provider].exclusions = []
    }

    // MARK: Synchronization

    private func performSync(_ provider: ExternalProvider) async {
        var config = settings[provider]
        guard config.mode != .off else { return }
        access.refresh()
        let timestamp = now()
        let linked = store.events.filter { $0.source?.key.provider == provider }
        guard access.access(provider).canRead else {
            // Keep last snapshots, but show that the source cannot be read.
            store.apply(upserts: linked.compactMap { mark($0, .inaccessible) })
            config.lastError = "\(provider.name) full access is not available. Existing countdowns keep their last synced values."
            settings[provider] = config
            return
        }

        var discovered: [SourceKey: ExternalItem] = [:]
        var exportLinks: [(UUID, ExternalProvider, String)] = []
        if config.mode == .allMatching {
            for item in await query(provider) {
                if let id = countdownID(linkedBy: item), let own = store.event(id), own.source == nil {
                    // An item this app exported: associate, never re-import.
                    if own.exportLink(provider) == nil { exportLinks.append((id, provider, item.key.itemID)) }
                } else if ineligibility(item) == nil || store.events.contains(where: { $0.source?.key == item.key }) {
                    discovered[item.key] = item
                }
            }
        }
        var targets: [SourceKey: String] = [:]
        for event in linked { if let source = event.source { targets[source.key] = source.containerID } }
        for selection in config.selected { targets[selection.key] = targets[selection.key] ?? selection.containerID }
        for item in discovered.values { targets[item.key] = item.containerID }
        for key in config.exclusions where linked.first(where: { $0.source?.key == key }) == nil { targets[key] = nil }

        var upserts: [CountdownEvent] = []
        for (key, containerID) in targets.sorted(by: { $0.key.itemID < $1.key.itemID }) {
            let result: ItemLookup
            if let item = discovered[key] { result = .found(item) }
            else { result = await access.adapter.lookup(key, containerID: containerID) }
            let existing = linked.first { $0.source?.key == key }
            switch result {
            case .found(let item):
                if let id = countdownID(linkedBy: item), let own = store.event(id), own.source == nil {
                    // An item this app exported: associate, never re-import.
                    if own.exportLink(provider) == nil { exportLinks.append((id, provider, item.key.itemID)) }
                    continue
                }
                if let existing {
                    if let updated = apply(item, to: existing, at: timestamp), updated != existing { upserts.append(updated) }
                } else if item.deadline != nil, !item.isCompleted {
                    upserts.append(makeCountdown(item, at: timestamp))
                }
            case .deleted:
                if let existing, let updated = mark(existing, .missing) { upserts.append(updated) }
            case .inaccessible:
                if let existing, let updated = mark(existing, .inaccessible) { upserts.append(updated) }
            }
        }
        for (id, provider, itemID) in exportLinks {
            if let index = upserts.firstIndex(where: { $0.id == id }) {
                upserts[index].setExportLink(ExportLink(itemID: itemID, fingerprint: "", exportedAt: timestamp), for: provider)
            } else if var event = store.event(id) {
                event.setExportLink(ExportLink(itemID: itemID, fingerprint: "", exportedAt: timestamp), for: provider)
                upserts.append(event)
            }
        }
        store.apply(upserts: upserts)
        config = settings[provider]
        config.lastSuccess = timestamp
        config.lastError = nil
        settings[provider] = config
    }

    private func mark(_ event: CountdownEvent, _ status: SourceStatus) -> CountdownEvent? {
        guard event.source?.status != status else { return nil }
        var copy = event
        copy.source?.status = status
        return copy
    }

    func makeCountdown(_ item: ExternalItem, at timestamp: Date) -> CountdownEvent {
        let deadline = item.deadline!
        var event = CountdownEvent(
            title: item.title, date: deadline,
            timeZoneIdentifier: item.timeZoneIdentifier.flatMap { EventTimeZone.resolve($0) == nil ? nil : $0 } ?? TimeZone.current.identifier,
            createdAt: timestamp, startDate: min(timestamp, deadline.addingTimeInterval(-1))
        )
        event.source = SourceLink(key: item.key, containerID: item.containerID, externalID: item.externalID,
                                  isDateOnly: item.isDateOnly, completed: item.isCompleted, status: .current, lastSynced: timestamp)
        return event
    }

    /// Updates source-owned fields only; start, critical window, and pinning
    /// stay local. A start that no longer precedes the deadline is kept and
    /// flagged for correction rather than rewritten.
    private func apply(_ item: ExternalItem, to event: CountdownEvent, at timestamp: Date) -> CountdownEvent? {
        var copy = event
        copy.title = item.title
        if let deadline = item.deadline {
            copy.date = deadline
            if let zone = item.timeZoneIdentifier, EventTimeZone.resolve(zone) != nil { copy.timeZoneIdentifier = zone }
            else if item.isDateOnly { copy.timeZoneIdentifier = TimeZone.current.identifier }
        }
        copy.source?.containerID = item.containerID
        copy.source?.externalID = item.externalID
        copy.source?.isDateOnly = item.isDateOnly
        copy.source?.completed = item.isCompleted
        copy.source?.status = .current
        // Avoid rewriting storage when nothing changed.
        var comparable = copy
        comparable.source?.lastSynced = event.source?.lastSynced ?? timestamp
        if comparable == event { return event }
        copy.source?.lastSynced = timestamp
        return copy
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
    }
}
