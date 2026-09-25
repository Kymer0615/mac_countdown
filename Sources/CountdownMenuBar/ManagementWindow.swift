import AppKit
import SwiftUI
import ServiceManagement

enum ManagementTab: Int {
    case events, sync, settings, about
}

@MainActor
final class ManagementNavigation: ObservableObject {
    @Published var selectedTab = ManagementTab.events
}

@MainActor
final class ManagementWindow {
    private let window: NSWindow
    private let navigation = ManagementNavigation()
    init(store: EventStore, settings: CountdownSettings, access: IntegrationAccess, sync: CalendarSync,
         add: @escaping () -> Void, edit: @escaping (CountdownEvent) -> Void, delete: @escaping (CountdownEvent) -> Void) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Countdown Menu Bar"
        window.minSize = NSSize(width: 680, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ManagementView(
            store: store, settings: settings, access: access, sync: sync, navigation: navigation,
            add: add, edit: edit, delete: delete
        ))
        window.center()
    }

    func show(_ tab: ManagementTab? = nil) {
        if let tab { navigation.selectedTab = tab }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ManagementView: View {
    @ObservedObject var store: EventStore
    @ObservedObject var settings: CountdownSettings
    @ObservedObject var access: IntegrationAccess
    @ObservedObject var sync: CalendarSync
    @ObservedObject var navigation: ManagementNavigation
    @State private var deleteCandidate: CountdownEvent?
    let add: () -> Void
    let edit: (CountdownEvent) -> Void
    let delete: (CountdownEvent) -> Void

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            events.tabItem { Label("Events", systemImage: "calendar") }.tag(ManagementTab.events)
            SyncView(sync: sync, access: access).tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }.tag(ManagementTab.sync)
            settingsView.tabItem { Label("Settings", systemImage: "gearshape") }.tag(ManagementTab.settings)
            AboutView().tabItem { Label("About", systemImage: "info.circle") }.tag(ManagementTab.about)
        }
        .padding(20)
        .font(settings.swiftUIFont)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLoginStatus()
            if access.refresh() { sync.reloadContainers() }
        }
        .alert("Delete event?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })) {
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
            Button("Delete", role: .destructive) {
                if let event = deleteCandidate { delete(event) }
                deleteCandidate = nil
            }
        } message: {
            Text("\(deleteCandidate?.title ?? "This event") will be removed from your countdown list. Calendar and Reminders items are not deleted.")
        }
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Your countdowns").font(.title2.bold())
                    Text("Pin an event to show it in the menu bar.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Event…", action: add).keyboardShortcut("n")
            }
            if let error = store.loadError {
                Text(error).foregroundStyle(.red)
            }
            if store.events.isEmpty {
                Spacer()
                Text("No events yet. Add an event to start your first countdown.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(store.sortedEvents) { event in
                        HStack(spacing: 12) {
                            Button { store.select(event.id) } label: {
                                Image(systemName: store.selectedID == event.id ? "pin.fill" : "pin")
                            }.help("Show in menu bar")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title).bold()
                                Text(deadline(event)).font(.caption).foregroundStyle(.secondary)
                                Text("Starts \(format(event.startDate, event)) · critical window \(event.critical.label)").font(.caption).foregroundStyle(.secondary)
                                badges(event)
                            }
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                VStack(alignment: .trailing, spacing: 2) {
                                    HStack(spacing: 6) {
                                        if event.isCompleted(at: context.date) {
                                            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                                        } else {
                                            Image(nsImage: MoonIcon.image(progress: MoonProgress.value(for: event, now: context.date), urgency: MoonProgress.urgency(for: event, now: context.date)))
                                        }
                                        Text(CountdownFormat.compact(for: event, now: context.date)).monospacedDigit()
                                    }
                                    Text(MoonProgress.summary(for: event, now: context.date)).font(.caption2).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            Button("Edit…") { edit(event) }
                            Button { deleteCandidate = event } label: { Image(systemName: "trash") }.help("Delete event")
                        }.padding(.vertical, 6)
                    }
                }
            }
        }.padding()
    }

    @ViewBuilder private func badges(_ event: CountdownEvent) -> some View {
        let notes = statusNotes(event)
        if !notes.isEmpty {
            Text(notes.joined(separator: " · ")).font(.caption)
                .foregroundStyle(event.needsStartCorrection || event.source.map { $0.status != .current } == true ? .orange : .secondary)
        }
    }

    private func statusNotes(_ event: CountdownEvent) -> [String] {
        var notes: [String] = []
        if let source = event.source {
            notes.append("Synced from \(source.key.provider.name)" + (source.isDateOnly ? (source.key.provider == .calendar ? " (all-day: counts to midnight at the start of the day)" : " (date only: counts to 23:59:59)") : ""))
            if source.completed { notes.append("Completed in Reminders") }
            if source.status == .missing { notes.append("Source deleted or moved; last values kept") }
            if source.status == .inaccessible { notes.append("Source not accessible; last values kept") }
        }
        if event.calendarExport != nil { notes.append("In Calendar") }
        if event.reminderExport != nil { notes.append("In Reminders") }
        if event.needsStartCorrection { notes.append("Start is after the new deadline. Edit to correct") }
        return notes
    }

    private func format(_ date: Date, _ event: CountdownEvent) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = event.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func deadline(_ event: CountdownEvent) -> String {
        "\(format(event.date, event)) · \(event.timeZoneIdentifier)"
    }

    private var settingsView: some View {
        Form {
            Section("Startup") {
                Toggle("Start at login", isOn: Binding(get: { settings.loginStatus == .enabled || settings.loginStatus == .requiresApproval }, set: settings.setStartAtLogin))
                if settings.loginStatus == .requiresApproval {
                    Text("Approval is needed in System Settings.").foregroundStyle(.orange)
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error = settings.loginError { Text(error).foregroundStyle(.red) }
            }
            Section("Menu bar and events window") {
                Picker("Font style", selection: $settings.fontStyle) {
                    ForEach(CountdownSettings.styles, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text("Font size: \(Int(settings.fontSize)) pt")
                    Slider(value: $settings.fontSize, in: 10...22, step: 1)
                }
                Text("Vacation · 3d 8h").font(settings.swiftUIFont)
                Text("Widgets use their own system-sized typography to fit each widget size.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Moon phases") {
                Text("The moon stays full until each event’s start, wanes to empty at its critical window, then fills toward red as the deadline approaches. Set the start and critical window in each event’s editor; the default window is 24 hours.")
            }
            Section("Calendar and Reminders access") {
                ForEach(ExternalProvider.allCases) { provider in
                    IntegrationStatusRow(access: access, provider: provider)
                }
                Text("Access lets you add countdowns to Calendar or Reminders and sync items into countdowns. Local countdowns work without it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Siri and Shortcuts") {
                Text("Use Create Countdown in the Shortcuts app, or say ‘Create a countdown in Countdown Menu Bar’ to Siri. Siri availability depends on your Mac’s language and settings.")
                Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
            }
        }.formStyle(.grouped)
        .onAppear {
            settings.refreshLoginStatus()
            access.refresh()
        }
    }
}

struct IntegrationStatusRow: View {
    @ObservedObject var access: IntegrationAccess
    let provider: ExternalProvider

    var body: some View {
        let state = access.access(provider)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                Text(description(state)).font(.caption).foregroundStyle(state.canRead ? Color.secondary : Color.orange)
                if let problem = access.requestProblem[provider] {
                    Text(problem).font(.caption).foregroundStyle(.red)
                    Button("Open System Settings") { access.openSystemSettings(provider) }.controlSize(.small)
                }
            }
            Spacer()
            if state.canRequest {
                Button(state.status == .writeOnly ? "Request Full Access" : "Request Access") { Task { await access.request(provider) } }
            } else if !state.canRead {
                Button("Open System Settings") { access.openSystemSettings(provider) }
            }
        }
    }

    private func description(_ state: ServiceAccess) -> String {
        switch state.status {
        case .fullAccess: return "Full access: can add items and sync."
        case .writeOnly: return "Add-only access: can add events, but cannot sync or update them."
        case .notDetermined: return "Not requested yet."
        case .denied: return "Denied. Allow access in System Settings → Privacy & Security."
        case .restricted: return "Restricted by this Mac’s settings."
        case .unknown: return "Unknown status; treated as not allowed."
        }
    }
}

struct AboutView: View {
    static let repository = URL(string: "https://github.com/Kymer0615/mac_countdown")!
    static let coffee = URL(string: "https://buymeacoffee.com/ziyang")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        return "Version \(short) (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            Text("Countdown Menu Bar").font(.title.bold())
            Text(version).foregroundStyle(.secondary)
            Text("Exact countdowns in your menu bar and desktop widgets, with moon phases, time zones, and Calendar and Reminders sync.")
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 12) {
                Button { NSWorkspace.shared.open(Self.repository) } label: {
                    Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityHint("Opens github.com/Kymer0615/mac_countdown in your browser")
                Button { NSWorkspace.shared.open(Self.coffee) } label: {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                }
                .accessibilityHint("Opens buymeacoffee.com/ziyang in your browser")
            }
            .controlSize(.large)
            Text("Links open in your default browser.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
