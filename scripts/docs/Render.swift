import AppKit
import SwiftUI
import WidgetKit

@main
struct DocumentationCapture {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        try renderMoonAnimation()
        let now = Date()
        let events = [
            CountdownEvent(title: "Project launch", date: now.addingTimeInterval(3 * 86400 + 8 * 3600 + 50), timeZoneIdentifier: "UTC"),
            CountdownEvent(title: "Design review", date: now.addingTimeInterval(18 * 86400 + 50), timeZoneIdentifier: "AoE"),
            CountdownEvent(title: "Vacation", date: now.addingTimeInterval(49 * 86400 + 50), timeZoneIdentifier: "Europe/London"),
            CountdownEvent(title: "Birthday", date: now.addingTimeInterval(72 * 86400 + 50), timeZoneIdentifier: "Europe/London"),
            CountdownEvent(title: "Marathon", date: now.addingTimeInterval(92 * 86400 + 50), timeZoneIdentifier: "America/New_York"),
            CountdownEvent(title: "New adventure", date: now.addingTimeInterval(150 * 86400 + 50), timeZoneIdentifier: "UTC"),
            CountdownEvent(title: "Next milestone", date: now.addingTimeInterval(180 * 86400), timeZoneIdentifier: "UTC")
        ]
        // This standalone executable has its own preferences domain, never the app's.
        UserDefaults.standard.set(try JSONEncoder().encode(events), forKey: "countdown.events")
        UserDefaults.standard.set(events[0].id.uuidString, forKey: "countdown.selectedEventID")
        defer {
            UserDefaults.standard.removeObject(forKey: "countdown.events")
            UserDefaults.standard.removeObject(forKey: "countdown.selectedEventID")
        }
        for (family, size, name, capacity) in [
            (WidgetFamily.systemSmall, CGSize(width: 170, height: 170), "small", 1),
            (.systemMedium, CGSize(width: 360, height: 170), "medium", 2),
            (.systemLarge, CGSize(width: 360, height: 360), "large", 6)
        ] {
            let entry = CountdownEntry(date: now, page: WidgetEventPage(events: events, requestedPage: 0, capacity: capacity, now: now))
            let content = CountdownWidgetContent(entry: entry, family: family)
                .environment(\.colorScheme, .dark).padding(16)
                .frame(width: size.width, height: size.height)
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 22))
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/images/widget-\(name).png"))
            window.close()
        }
        let delegate = CountdownApp()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let status = Mirror(reflecting: delegate).children.first { $0.label == "statusItem" }!.value as! NSStatusItem
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let backdrop = NSWindow(contentRect: status.button!.window!.screen!.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1)
        backdrop.level = .floating
        backdrop.orderFrontRegardless()
        let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
            MainActor.assumeIsolated {
                let status = Mirror(reflecting: delegate).children.first { $0.label == "statusItem" }!.value as! NSStatusItem
                let menu = Mirror(reflecting: delegate).children.first { $0.label == "menu" }!.value as! NSMenu
                let menuWindow = NSApp.windows.first { $0.isVisible && $0 !== backdrop && $0.frame.height > 100 }!
                let rect = status.button!.window!.frame
                let capture = CGRect(x: rect.minX, y: NSScreen.screens[0].frame.height - rect.maxY + 2, width: rect.width, height: rect.height - 2)
                func captureImage(_ arguments: [String]) {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x"] + arguments
                    try! process.run()
                    process.waitUntilExit()
                    precondition(process.terminationStatus == 0, "Screen capture failed")
                }
                captureImage(["-R\(Int(capture.minX)),\(Int(capture.minY)),\(Int(capture.width)),\(Int(capture.height))", "docs/images/menu-bar.png"])
                captureImage(["-o", "-l", "\(menuWindow.windowNumber)", "docs/images/event-menu.png"])
                backdrop.close()
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        status.button?.performClick(nil)
        withExtendedLifetime(delegate) {}
    }
}
