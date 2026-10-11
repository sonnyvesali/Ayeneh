import SwiftUI

struct VideoTimeline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var playback: PlaybackController
    @ObservedObject var review: ClipReviewController
    @State private var dragging = false
    @State private var fineScale: TimelineScale?
    @State private var viewportScale: TimelineScale?
    @State private var gestureScale: TimelineScale?
    @State private var holdTask: Task<Void, Never>?
    @State private var pointerX = 0.0
    @State private var anchorX = 0.0
    @State private var anchorTime = 0.0
    @State private var holdOriginX = 0.0

    private var scale: TimelineScale {
        fineScale ?? viewportScale ?? .full(duration: playback.duration)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label("Timeline", systemImage: "film.stack").font(.caption.weight(.semibold))
                Text(fineScale == nil ? "Hold to zoom" : "Fine scrubbing · 10×")
                    .foregroundStyle(.secondary)
                Spacer()
                Button { zoom(by: 2) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out").disabled(viewportScale == nil)
                Text("\((playback.duration / max(scale.span, 0.001)).formatted(.number.precision(.fractionLength(0...1))))×")
                    .frame(minWidth: 32)
                Button { zoom(by: 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in").disabled(scale.span <= 0.1)
                Button(viewportScale == nil ? "Fit" : "Overview") {
                    review.showOverview()
                    withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.25)) { viewportScale = nil; fineScale = nil }
                }.help("Return to the full video timeline")
                Group {
                    Button("Fit Clip") {
                        guard let range = review.draft?.range else { return }
                        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.25)) {
                            viewportScale = .focused(duration: playback.duration, range: range)
                        }
                    }.disabled(review.draft == nil)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            GeometryReader { geometry in
                let width = geometry.size.width
                TimelineRuler(lower: scale.lower, span: scale.span,
                              duration: playback.duration, currentTime: playback.currentTime)
                .frame(height: 66)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        pointerX = value.location.x
                        if !dragging {
                            gestureScale = scale
                            review.deselectIfOutside(at: scale.time(at: pointerX, width: width))
                            dragging = true
                            holdOriginX = pointerX
                            playback.beginScrubbing()
                            holdTask = Task { @MainActor in
                                do { try await Task.sleep(for: .milliseconds(500)) }
                                catch { return }
                                guard dragging else { return }
                                anchorTime = playback.currentTime
                                anchorX = pointerX
                                withAnimation(.easeInOut(duration: 0.28)) {
                                    fineScale = .zoomed(duration: playback.duration, span: max(0.02, scale.span / 10), center: anchorTime,
                                                        anchorFraction: width > 0 ? anchorX / width : 0.5)
                                }
                            }
                        }
                        if fineScale == nil, abs(pointerX - holdOriginX) > 4 {
                            holdTask?.cancel()
                        }
                        playback.seekFromTimeline(to: targetTime(x: pointerX, width: width))
                    }
                    .onEnded { value in
                        let time = targetTime(x: value.location.x, width: width)
                        holdTask?.cancel()
                        holdTask = nil
                        dragging = false
                        playback.endScrubbing(at: time)
                        gestureScale = nil
                        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.28)) {
                            fineScale = nil
                            if review.draft == nil { viewportScale = nil }
                        }
                    })
            }
            .frame(height: 66)
            .accessibilityElement()
            .accessibilityLabel("Video timeline")
            .accessibilityValue(timeLabel(playback.currentTime))
            .accessibilityAdjustableAction { direction in
                playback.beginScrubbing()
                playback.endScrubbing(at: playback.currentTime + (direction == .increment ? 1 : -1))
            }
            Group {
                Divider()
                ClipTimeline(review: review, playback: playback, store: review.store,
                             templates: review.templates,
                             lower: scale.lower, span: scale.span)
            }
            if let viewportScale, viewportScale.span < playback.duration {
                HStack {
                    Text(timeLabel(viewportScale.lower)).font(.caption2.monospacedDigit())
                    TimelineOverview(duration: playback.duration, scale: viewportScale, currentTime: playback.currentTime,
                                     clips: review.savedClips, review: review, templates: review.templates, onMove: { lower in
                        self.viewportScale = TimelineScale(lower: lower, upper: lower + viewportScale.span)
                    })
                    Text(timeLabel(viewportScale.upper)).font(.caption2.monospacedDigit())
                }.foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.2), lineWidth: 1))
        .disabled(!playback.isReady || playback.isLoading)
        .opacity(playback.isReady ? 1 : 0.5)
        .onDisappear {
            holdTask?.cancel()
            if dragging { playback.endScrubbing(at: playback.currentTime) }
        }
        .onChange(of: playback.currentVideoID) { _, _ in viewportScale = nil; fineScale = nil }
        .onChange(of: review.focusRevision) { _, _ in
            let range = review.focusRequest
            if range == nil, dragging { return }
            holdTask?.cancel()
            withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.3)) {
                fineScale = nil
                viewportScale = range.map { .focused(duration: playback.duration, range: $0) }
            }
        }
    }

    private func zoom(by multiplier: Double) {
        let center = scale.time(at: 0.5, width: 1)
        let anchor = scale.lower <= playback.currentTime && playback.currentTime <= scale.upper ? playback.currentTime : center
        let newSpan = min(playback.duration, max(0.1, scale.span * multiplier))
        withAnimation(.easeInOut(duration: 0.25)) {
            viewportScale = newSpan >= playback.duration ? nil : .zoomed(duration: playback.duration, span: newSpan, center: anchor)
        }
    }

    private func targetTime(x: Double, width: Double) -> Double {
        if let fineScale {
            guard width > 0 else { return anchorTime }
            return min(max(fineScale.lower, anchorTime + (x - anchorX) / width * fineScale.span), fineScale.upper)
        }
        return (gestureScale ?? scale).time(at: x, width: width)
    }
}
