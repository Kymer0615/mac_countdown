import SwiftUI

struct SyncView: View {
    @ObservedObject var sync: CalendarSync
    @ObservedObject var access: IntegrationAccess
    @State private var provider = ExternalProvider.calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Sync from Calendar and Reminders").font(.title2.bold())
                    Text("One-way: changes in Calendar or Reminders update their countdowns while this app is running. Nothing is imported until you choose items or sync all matching.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sync Now") { Task { await sync.syncActive() } }.disabled(!sync.isActive || sync.isSyncing)
            }
            Picker("Source", selection: $provider) {
                ForEach(ExternalProvider.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            ProviderSyncView(sync: sync, access: access, provider: provider).id(provider)
        }
        .padding()
        .onAppear { sync.reloadContainers() }
    }
}

private struct ProviderSyncView: View {
    @ObservedObject var sync: CalendarSync
    @ObservedObject var access: IntegrationAccess
    let provider: ExternalProvider
    @State private var checked = Set<SourceKey>()
    @State private var isLoading = false

    private var config: ProviderSyncConfig { sync.settings[provider] }
    private var items: [ExternalItem] { sync.candidates[provider] ?? [] }
    private var eligible: [ExternalItem] { items.filter { sync.ineligibility($0) == nil } }

    var body: some View {
        if !access.access(provider).canRead {
            VStack(alignment: .leading, spacing: 8) {
                IntegrationStatusRow(access: access, provider: provider)
                Text("Syncing reads your \(provider == .calendar ? "events" : "reminders"), so it needs full access. Existing synced countdowns keep their last values.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                filters
                list
                status
                actions
            }
            .task { await reload() }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ProviderSyncConfig, T>) -> Binding<T> {
        Binding(get: { sync.settings[provider][keyPath: keyPath] }, set: { sync.settings[provider][keyPath: keyPath] = $0 })
    }

    private func reload() async {
        isLoading = true
        await sync.reloadCandidates(provider)
        checked = checked.intersection(Set(eligible.map(\.key)))
        isLoading = false
    }

    @ViewBuilder private var filters: some View {
        HStack(alignment: .top, spacing: 14) {
            Menu {
                let all = sync.containers[provider] ?? []
                Button("All \(provider == .calendar ? "calendars" : "lists")") { sync.settings[provider].containerIDs = nil; Task { await reload() } }
                Divider()
                ForEach(all) { container in
                    Toggle(container.title, isOn: Binding(
                        get: { sync.selectedContainerIDs(provider).contains(container.id) },
                        set: { on in
                            var ids = sync.selectedContainerIDs(provider)
                            if on { ids.insert(container.id) } else { ids.remove(container.id) }
                            sync.settings[provider].containerIDs = Array(ids)
                            Task { await reload() }
                        }
                    ))
                }
            } label: {
                let count = sync.selectedContainerIDs(provider).count
                Text("\(count) of \((sync.containers[provider] ?? []).count) \(provider == .calendar ? "calendars" : "lists")")
            }
            .fixedSize()
            TextField("Search titles", text: binding(\.search)).onSubmit { Task { await reload() } }
            if provider == .calendar {
                let (start, end) = sync.range(for: config)
                DatePicker("From", selection: Binding(get: { start }, set: { sync.settings[provider].rangeStart = $0; Task { await reload() } }), displayedComponents: .date)
                    .fixedSize()
                DatePicker("To", selection: Binding(get: { end }, set: { sync.settings[provider].rangeEnd = $0; Task { await reload() } }), displayedComponents: .date)
                    .fixedSize()
            }
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh list")
        }
    }

    private var list: some View {
        List {
            if items.isEmpty {
                Text(isLoading ? "Loading…" : (provider == .calendar ? "No events in the selected calendars and date range." : "No incomplete reminders in the selected lists."))
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                let reason = sync.ineligibility(item)
                HStack {
                    Toggle(isOn: Binding(get: { checked.contains(item.key) }, set: { if $0 { checked.insert(item.key) } else { checked.remove(item.key) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(detail(item)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(reason != nil && reason != "Removed earlier")
                    Spacer()
                    if let reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .frame(minHeight: 160)
    }

    private func detail(_ item: ExternalItem) -> String {
        guard let deadline = item.deadline else { return "\(item.containerTitle) · no due date" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = item.isDateOnly ? .none : .short
        let note = item.isDateOnly ? (provider == .calendar ? " · all day (counts to midnight at the start of the day)" : " · date only (counts to 23:59:59)") : ""
        return "\(item.containerTitle) · \(formatter.string(from: deadline))\(note)"
    }

    @ViewBuilder private var status: some View {
        let modeText: String = {
            switch config.mode {
            case .off: return "Sync is off."
            case .selected: return "Following \(config.selected.count) selected item\(config.selected.count == 1 ? "" : "s")."
            case .allMatching: return "Following all matching items (\(eligible.count) new of \(items.count) shown)."
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            Text(modeText + " \(eligible.count) eligible to add.")
            if let success = config.lastSuccess {
                Text("Last synced \(success.formatted(date: .abbreviated, time: .standard)).").font(.caption).foregroundStyle(.secondary)
            }
            if let error = config.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Undated reminders cannot be synced; use Add Event to create a local countdown for them. Background sync while the app is quit is not provided.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button("Sync Selected (\(checked.count))") {
                let chosen = items.filter { checked.contains($0.key) }
                checked = []
                Task { await sync.activateSelected(provider, items: chosen) }
            }.disabled(checked.isEmpty || sync.isSyncing)
            Button("Sync All Matching (\(eligible.count))") { Task { await sync.activateAll(provider) } }
                .disabled(sync.isSyncing)
                .help("Also follows new items that match these sources, dates, and search.")
            Spacer()
            if !config.exclusions.isEmpty {
                Button("Clear \(config.exclusions.count) Removed") { sync.clearExclusions(provider); Task { await reload() } }
                    .help("Let sync recreate countdowns you removed.")
            }
            Button("Stop Sync") { sync.stop(provider) }
                .disabled(config.mode == .off)
                .help("Keeps countdowns as local copies. Does not change permissions or source items.")
        }
    }
}
