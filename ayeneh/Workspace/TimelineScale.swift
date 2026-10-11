import Foundation

struct TimelineScale {
    let lower: Double
    let upper: Double
    var span: Double { upper - lower }

    static func full(duration: Double) -> Self {
        Self(lower: 0, upper: max(0, duration))
    }

    static func fine(duration: Double, center: Double, anchorFraction: Double = 0.5) -> Self {
        zoomed(duration: duration, span: max(0, duration) / 10, center: center, anchorFraction: anchorFraction)
    }

    static func zoomed(duration: Double, span requestedSpan: Double, center: Double, anchorFraction: Double = 0.5) -> Self {
        let span = min(max(0, requestedSpan), max(0, duration))
        let fraction = min(max(0, anchorFraction), 1)
        let lower = min(max(0, center - span * fraction), max(0, duration - span))
        return Self(lower: lower, upper: lower + span)
    }

    static func focused(duration: Double, range: ClipRange) -> Self {
        zoomed(duration: duration, span: max(0.1, range.duration * 2), center: (range.start + range.end) / 2)
    }

    func time(at x: Double, width: Double) -> Double {
        guard width > 0 else { return lower }
        return lower + min(max(0, x / width), 1) * span
    }

    func position(for time: Double, width: Double) -> Double {
        guard span > 0 else { return 0 }
        return min(max(0, (time - lower) / span), 1) * max(0, width)
    }
}

func timeLabel(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00.000" }
    let milliseconds = Int((max(0, seconds) * 1000).rounded())
    let hours = milliseconds / 3_600_000
    let minutes = milliseconds / 60_000 % 60
    let remainder = milliseconds / 1000 % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d.%03d", hours, minutes, remainder, milliseconds % 1000)
    }
    return String(format: "%02d:%02d.%03d", minutes, remainder, milliseconds % 1000)
}
