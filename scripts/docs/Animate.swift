import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
func renderMoonAnimation() throws {
    let width = 1000, height = 340
    let output = URL(fileURLWithPath: "docs/images/moon-progress.gif")
    let stages: [(Double, String)] = [
        (60 * 86400, "Just created"), (30 * 86400, "Waning moon"),
        (7 * 86400, "One week away"),
        (3 * 86400 + 8 * 3600, "Days away"), (86400, "Critical window"),
        (8 * 3600 + 24 * 60, "Hours away"), (3600, "One hour away"),
        (24 * 60 + 16, "Minutes away"), (1, "Almost there"), (0, "Deadline reached")
    ]
    let frameCount = (stages.count - 1) * 14 + 1
    let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frameCount, nil)!
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for index in 0..<frameCount {
        let segment = min(index / 14, stages.count - 2)
        let fraction = index == frameCount - 1 ? 1 : Double(index % 14) / 14
        let remaining = stages[segment].0 + (stages[segment + 1].0 - stages[segment].0) * fraction
        let event = CountdownEvent(title: "Vacation", date: Date(timeIntervalSince1970: 60 * 86400), createdAt: Date(timeIntervalSince1970: 0))
        let instant = event.date.addingTimeInterval(-remaining)
        let progress = MoonProgress.value(for: event, now: instant)
        let urgency = MoonProgress.urgency(for: event, now: instant)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.11, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor, _ weight: NSFont.Weight = .regular) {
            (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        }
        text("CLOSER DEADLINE. CLEARER COUNTDOWN.", 40, 290, 15, NSColor(white: 0.65, alpha: 1), .semibold)
        text("Full → waning → critical → countdown", 40, 242, 29, .white, .semibold)
        NSColor(white: 1, alpha: 0.07).setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 109, width: 920, height: 103), xRadius: 20, yRadius: 20).fill()
        let icon = remaining <= 0
            ? NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Deadline reached")!.withSymbolConfiguration(.init(paletteColors: [.white]))!
            : MoonIcon.image(progress: progress, urgency: urgency)
        icon.draw(in: NSRect(x: 69, y: 133, width: 55, height: 55))
        let now = Date(timeIntervalSince1970: 0)
        let countdown = CountdownFormat.compact(until: now.addingTimeInterval(remaining), now: now)
        text("Vacation · \(countdown)", 148, 139, 35, .white, .medium)
        text(stages[index == frameCount - 1 ? stages.count - 1 : segment].1, 722, 151, 17, NSColor(white: 0.7, alpha: 1))
        for (i, seconds) in ([60 * 86400, 30 * 86400, 86400, 12 * 3600, 1] as [Double]).enumerated() {
            let x = CGFloat(64 + i * 204)
            MoonIcon.image(progress: MoonProgress.value(for: event, now: event.date.addingTimeInterval(-seconds)), urgency: MoonProgress.urgency(for: event, now: event.date.addingTimeInterval(-seconds))).draw(in: NSRect(x: x, y: 54, width: 24, height: 24))
            text(["Created", "30 days", "24 hours", "12 hours", "Deadline"][i], x + 34, 57, 15, NSColor(white: 0.75, alpha: 1))
        }
        text("Accelerated illustration · the app updates once per second", 40, 19, 13, NSColor(white: 0.48, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
        if index == 0 {
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/images/moon-progress.png"))
        }
        let delay = index % 14 == 0 || index == frameCount - 1 ? 1.0 : 0.07
        CGImageDestinationAddImage(destination, bitmap.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
