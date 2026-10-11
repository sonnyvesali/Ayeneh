import SwiftUI

/// Animate the time-to-position transform, so every tick moves continuously during zoom.
struct TimelineRuler: View, Animatable {
    var lower: Double
    var span: Double
    let duration: Double
    let currentTime: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(lower, span) }
        set { lower = newValue.first; span = newValue.second }
    }

    var body: some View {
        Canvas { context, size in
            guard span > 0, size.width > 0 else { return }
            let baseline = 48.0
            let x = min(max(0, (currentTime - lower) / span * size.width), size.width)
            context.fill(Path(CGRect(x: 0, y: 30, width: size.width, height: 24)),
                         with: .color(.primary.opacity(0.025)))
            context.fill(Path(CGRect(x: 0, y: 30, width: x, height: 24)),
                         with: .color(.accentColor.opacity(0.09)))

            let major = Self.tickInterval(span * 110 / size.width)
            let minor = major / 5
            let first = Int(floor(lower / minor))
            let last = Int(ceil((lower + span) / minor))
            for index in first...last {
                let time = Double(index) * minor
                guard time >= 0, time <= duration else { continue }
                let tickX = (time - lower) / span * size.width
                guard tickX >= 0, tickX <= size.width else { continue }
                let isMajor = index.isMultiple(of: 5)
                var tick = Path()
                tick.move(to: CGPoint(x: tickX, y: isMajor ? 30 : 39))
                tick.addLine(to: CGPoint(x: tickX, y: baseline))
                context.stroke(tick, with: .color(.secondary.opacity(isMajor ? 0.65 : 0.3)), lineWidth: 1)
                if isMajor {
                    let label = Text(Self.rulerLabel(time, interval: major))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    let resolved = context.resolve(label)
                    let labelWidth = resolved.measure(in: size).width
                    let labelX = min(max(labelWidth / 2, tickX), size.width - labelWidth / 2)
                    context.draw(resolved, at: CGPoint(x: labelX, y: 16))
                }
            }
            var track = Path()
            track.move(to: CGPoint(x: 0, y: baseline))
            track.addLine(to: CGPoint(x: size.width, y: baseline))
            context.stroke(track, with: .color(.secondary.opacity(0.3)), lineWidth: 1)

            var playhead = Path()
            playhead.move(to: CGPoint(x: x, y: 27))
            playhead.addLine(to: CGPoint(x: x, y: 59))
            context.stroke(playhead, with: .color(.accentColor), lineWidth: 2)
            var cap = Path()
            cap.move(to: CGPoint(x: x - 5, y: 24))
            cap.addLine(to: CGPoint(x: x + 5, y: 24))
            cap.addLine(to: CGPoint(x: x + 5, y: 29))
            cap.addLine(to: CGPoint(x: x, y: 34))
            cap.addLine(to: CGPoint(x: x - 5, y: 29))
            cap.closeSubpath()
            context.fill(cap, with: .color(.accentColor))
        }
        .clipped()
    }

    static func tickInterval(_ desired: Double) -> Double {
        let power = pow(10, floor(log10(max(desired, 0.001))))
        let fraction = desired / power
        return (fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10) * power
    }

    private static func rulerLabel(_ time: Double, interval: Double) -> String {
        if interval < 1 { return String(format: "%.2fs", time) }
        let seconds = Int(time.rounded())
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
