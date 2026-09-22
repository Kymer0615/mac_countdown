import Foundation

enum MoonProgress {
    /// Proximity anchors, independent of when the event was created.
    static func value(remaining: TimeInterval) -> Double {
        let anchors: [(TimeInterval, Double)] = [
            (30 * 86_400, 0), (7 * 86_400, 0.25),
            (86_400, 0.5), (3_600, 0.75), (0, 1)
        ]
        if remaining >= anchors[0].0 { return 0 }
        if remaining <= 0 { return 1 }
        for index in 0..<(anchors.count - 1) {
            let (start, startFill) = anchors[index]
            let (end, endFill) = anchors[index + 1]
            if remaining >= end {
                let fraction = (start - remaining) / (start - end)
                return startFill + fraction * (endFill - startFill)
            }
        }
        return 1
    }

    static func hue(progress: Double) -> Double {
        (1 - min(1, max(0, progress))) / 3
    }
}
