import SwiftUI

struct TimelineOverview: View {
    let duration: Double
    let scale: TimelineScale
    let currentTime: Double
    let clips: [VideoClip]
    @ObservedObject var review: ClipReviewController
    @ObservedObject var templates: ReviewTemplateStore
    let onMove: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.1))
                Canvas { context, size in
                    guard duration > 0 else { return }
                    for clip in clips {
                        let x = clip.range.start / duration * size.width
                        let length = max(2, clip.range.duration / duration * size.width)
                        context.fill(Path(CGRect(x: x, y: 5, width: length, height: 8)), with: .color(review.color(for: clip).swatch.opacity(0.6)))
                        if let assessment = review.assessmentColor(for: clip) {
                            context.fill(Path(CGRect(x: x, y: 11, width: length, height: 2)), with: .color(assessment.swatch))
                        }
                    }
                    let playhead = currentTime / duration * size.width
                    context.fill(Path(CGRect(x: playhead, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.6)))
                }.allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1))
                    .frame(width: max(8, duration > 0 ? scale.span / duration * width : width))
                    .offset(x: duration > 0 ? scale.lower / duration * width : 0)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard width > 0 else { return }
                onMove(min(max(0, value.location.x / width * duration - scale.span / 2), max(0, duration - scale.span)))
            })
        }
        .frame(height: 18)
        .help("Video overview · drag to move the focused timeline")
        .accessibilityElement()
        .accessibilityLabel("Video overview")
        .accessibilityValue("\(timeLabel(scale.lower)) to \(timeLabel(scale.upper)) of \(timeLabel(duration))")
        .accessibilityAdjustableAction { direction in
            onMove(min(max(0, scale.lower + (direction == .increment ? scale.span / 2 : -scale.span / 2)), max(0, duration - scale.span)))
        }
    }
}
