import AppKit
import SwiftUI
import ServiceManagement

@MainActor
private final class ManagementNavigation: ObservableObject {
    @Published var selectedTab = 0
}

@MainActor
final class ManagementWindow {
    private let window: NSWindow
    private let navigation = ManagementNavigation()
    init(store: EventStore, settings: CountdownSettings, add: @escaping () -> Void, edit: @escaping (CountdownEvent) -> Void) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Countdown Menu Bar"
        window.minSize = NSSize(width: 650, height: 440)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ManagementView(store: store, settings: settings, navigation: navigation, add: add, edit: edit))
        window.center()
    }
    func show(settingsTab: Bool = false) {
        if settingsTab { navigation.selectedTab = 1 }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ManagementView: View {
    @ObservedObject var store: EventStore
    @ObservedObject var settings: CountdownSettings
    @ObservedObject var navigation: ManagementNavigation
    @State private var deleteCandidate: CountdownEvent?
    let add: () -> Void
    let edit: (CountdownEvent) -> Void

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            events.tabItem { Label("Events", systemImage: "calendar") }.tag(0)
            settingsView.tabItem { Label("Settings", systemImage: "gearshape") }.tag(1)
        }
        .padding(20)
        .font(settings.swiftUIFont)
        .alert("Delete event?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })) {
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
            Button("Delete", role: .destructive) {
                if let event = deleteCandidate { store.delete(event.id) }
                deleteCandidate = nil
            }
        } message: { Text("\(deleteCandidate?.title ?? "This event") will be removed from your countdown list.") }
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
                                Text("Critical window: \(event.criticalHours.formatted()) hours").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(CountdownFormat.compact(until: event.date, now: context.date)).monospacedDigit()
                            }
                            Button("Edit…") { edit(event) }
                            Button { deleteCandidate = event } label: { Image(systemName: "trash") }.help("Delete event")
                        }.padding(.vertical, 6)
                    }
                }
            }
        }.padding()
    }

    private func deadline(_ event: CountdownEvent) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = event.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return "\(formatter.string(from: event.date)) · \(event.timeZoneIdentifier)"
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
                Text("The moon wanes from full at creation to empty at the critical window, then fills toward red as the deadline approaches. Set each event’s critical window in its editor; the default is 24 hours.")
            }
            Section("Calendar and Reminders") {
                Text("When adding an event, optionally create a Calendar event or Reminder. Calendar events last 30 minutes from the deadline; reminders are due at the deadline. The default calendar and reminder list are used. Copies are independent: later edits or deletions are not synchronized.")
            }
            Section("Siri and Shortcuts") {
                Text("Use Create Countdown in the Shortcuts app, or say ‘Create a countdown in Countdown Menu Bar’ to Siri. Siri availability depends on your Mac’s language and settings.")
                Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
            }
        }.formStyle(.grouped)
        .onAppear { settings.refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in settings.refreshLoginStatus() }
    }

}
