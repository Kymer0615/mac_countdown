import AppKit

enum MoonIcon {
    static func image(progress: Double, urgency: Double? = nil) -> NSImage {
        let fill = min(1, max(0, progress))
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let center = NSPoint(x: 10, y: 10)
            // The disk sits inside a separate neutral ring, so nothing is drawn
            // over the terminator and a thin unlit crescent stays visible.
            let radius = 6.75
            let disk = NSBezierPath(ovalIn: NSRect(x: 10 - radius, y: 10 - radius, width: radius * 2, height: radius * 2))
            NSColor.labelColor.withAlphaComponent(0.38).setFill()
            disk.fill()

            let color = NSColor(
                calibratedHue: MoonProgress.hue(progress: urgency ?? fill),
                saturation: 0.88, brightness: 0.88, alpha: 1
            )
            let phase = NSBezierPath()
            // The right limb and elliptical terminator form the lit area.
            // A linear terminator scale makes the illuminated area equal to fill.
            for step in 0...64 {
                let angle = Double.pi / 2 - Double(step) * Double.pi / 64
                let point = NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                if step == 0 { phase.move(to: point) } else { phase.line(to: point) }
            }
            for step in 0...64 {
                let angle = -Double.pi / 2 + Double(step) * Double.pi / 64
                phase.line(to: NSPoint(
                    x: center.x + (1 - 2 * fill) * radius * cos(angle),
                    y: center.y + radius * sin(angle)
                ))
            }
            phase.close()
            color.setFill()
            phase.fill()

            let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 16, height: 16))
            ring.lineWidth = 1.2
            color.withAlphaComponent(0.9).setStroke()
            ring.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Moon illuminated \(Int(fill * 100)) percent"
        return image
    }
}

@MainActor
final class MoonAnimator: NSObject {
    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private var current: Double?
    private var start: Double = 0
    private var target: Double = 0
    private var urgency: Double = 0
    private var startedAt: TimeInterval = 0

    init(button: NSStatusBarButton?) {
        self.button = button
        super.init()
    }

    func update(progress: Double, completed: Bool, urgency: Double? = nil) {
        self.urgency = urgency ?? progress
        if completed {
            reset()
            button?.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Deadline reached")
            return
        }
        guard current != nil else {
            current = progress
            target = progress
            button?.image = MoonIcon.image(progress: progress, urgency: self.urgency)
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            timer?.invalidate()
            timer = nil
            current = progress
            target = progress
            button?.image = MoonIcon.image(progress: progress, urgency: self.urgency)
            return
        }
        guard target != progress else {
            button?.image = MoonIcon.image(progress: progress, urgency: self.urgency)
            return
        }
        timer?.invalidate()
        start = current!
        target = progress
        startedAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        current = nil
        button?.image = nil
    }

    @objc private func tick() {
        let fraction = min(1, (ProcessInfo.processInfo.systemUptime - startedAt) / 0.3)
        let eased = fraction * fraction * (3 - 2 * fraction)
        let value = start + (target - start) * eased
        current = value
        button?.image = MoonIcon.image(progress: value, urgency: urgency)
        if fraction >= 1 {
            timer?.invalidate()
            timer = nil
        }
    }
}
