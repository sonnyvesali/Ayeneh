import SwiftUI

struct ClipTimeline: View, Animatable {
    @ObservedObject var review: ClipReviewController
    @ObservedObject var playback: PlaybackController
    @ObservedObject var store: ClipStore
    @ObservedObject var templates: ReviewTemplateStore
    var lower: Double
    var span: Double
    @State private var drawing: ClipRange?

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(lower, span) }
        set { lower = newValue.first; span = newValue.second }
    }
    private var scale: TimelineScale { TimelineScale(lower: lower, upper: lower + span) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Selection").font(.caption.weight(.medium))
                Spacer()
                Text("Drag to mark · I / O for boundaries").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(.secondary.opacity(0.08))
                        .contentShape(Rectangle())
                        .onTapGesture { review.clear() }
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                let a = time(value.startLocation.x, width: width)
                                let b = time(value.location.x, width: width)
                                drawing = ClipRange(start: min(a, b), end: max(a, b))
                            }
                            .onEnded { value in
                                drawing = nil
                                review.drawRange(from: time(value.startLocation.x, width: width),
                                                 to: time(value.location.x, width: width))
                            })
                    if let range = drawing ?? review.draft?.range, range.end >= scale.lower, range.start <= scale.upper {
                        let left = position(range.start, width: width)
                        let right = position(range.end, width: width)
                        RoundedRectangle(cornerRadius: 4).fill(selectionColor.opacity(0.25))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selectionColor, lineWidth: 1))
                            .frame(width: max(2, right - left)).offset(x: left)
                            .allowsHitTesting(false)
                        if drawing == nil {
                            if range.start >= scale.lower { handle(start: true, x: left, width: width) }
                            if range.end <= scale.upper { handle(start: false, x: right, width: width) }
                        }
                    }
                    if playback.currentTime >= scale.lower, playback.currentTime <= scale.upper {
                        Rectangle().fill(.primary.opacity(0.5)).frame(width: 1)
                            .offset(x: position(playback.currentTime, width: width)).allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: "clipLane")
            }.frame(height: 28)
            HStack {
                Text("Saved clips · \(review.savedClips.count)").font(.caption.weight(.medium))
                Spacer()
                Button("New Clip", systemImage: "plus") { review.newClip() }.buttonStyle(.borderless).font(.caption)
            }
            if review.savedClips.isEmpty {
                Text("Mark a range to add it to the clip lane.").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
                    .contentShape(Rectangle()).onTapGesture { review.clear() }
            } else {
                GeometryReader { geometry in
                    let placements = placements(width: geometry.size.width)
                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            ForEach(placements) { placement in
                                Button { review.select(placement.clip) } label: {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(review.color(for: placement.clip).swatch.opacity(review.draft?.id == placement.id ? 0.35 : 0.18))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 4).strokeBorder(review.color(for: placement.clip).swatch,
                                                lineWidth: review.draft?.id == placement.id ? 2 : 0.5)
                                        }
                                        .overlay(alignment: .bottom) {
                                            if let assessmentColor = review.assessmentColor(for: placement.clip) {
                                                Rectangle().fill(assessmentColor.swatch).frame(height: 3)
                                            }
                                        }
                                        .overlay(alignment: .leading) {
                                            if placement.width > 65 {
                                                Text(placement.clip.displayTitle).font(.caption2).lineLimit(1).padding(.horizontal, 5)
                                            }
                                        }
                                        .frame(width: placement.width, height: 22)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                                .offset(x: placement.x, y: CGFloat(placement.lane) * 26)
                                .help(review.hoverDetails(for: placement.clip))
                                .accessibilityLabel("Select \(placement.clip.displayTitle)")
                            }
                        }
                        .frame(width: geometry.size.width, height: max(50, CGFloat((placements.map(\.lane).max() ?? 0) + 1) * 26), alignment: .topLeading)
                        .background { Color.clear.contentShape(Rectangle()).onTapGesture { review.clear() } }
                    }
                }.frame(height: 50)
            }
        }
        .background {
            Canvas { context, size in
                guard span > 0, size.width > 0 else { return }
                let interval = TimelineRuler.tickInterval(span * 110 / size.width)
                for index in Int(floor(lower / interval))...Int(ceil((lower + span) / interval)) {
                    let x = (Double(index) * interval - lower) / span * size.width
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 20))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
                }
            }.allowsHitTesting(false)
        }
        .clipped()
        .disabled(!playback.isReady || playback.isLoading)
    }

    private func handle(start: Bool, x: Double, width: Double) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(selectionColor)
            .overlay(Image(systemName: "line.3.horizontal").font(.system(size: 7)).foregroundStyle(.white).rotationEffect(.degrees(90)))
            .frame(width: 20, height: 28).contentShape(Rectangle())
            .offset(x: min(max(0, x - 10), max(0, width - 20)))
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("clipLane"))
                .onChanged { value in
                    playback.pause()
                    review.setBoundary(start: start, time: time(value.location.x, width: width))
                }
                .onEnded { _ in
                    review.focusClip()
                }, including: .all)
            .accessibilityLabel(start ? "Clip start" : "Clip end")
            .accessibilityValue(clipTimeLabel(start ? review.draft?.range.start ?? 0 : review.draft?.range.end ?? 0))
            .accessibilityAdjustableAction { adjustment in
                let current = start ? review.draft?.range.start ?? 0 : review.draft?.range.end ?? 0
                review.setBoundary(start: start, time: current + (adjustment == .increment ? 0.033 : -0.033))
                review.focusClip()
            }
    }

    private var selectionColor: Color { review.draft.map { review.color(for: $0).swatch } ?? .accentColor }

    private func time(_ x: Double, width: Double) -> Double {
        scale.time(at: x, width: width)
    }
    private func position(_ time: Double, width: Double) -> Double {
        scale.position(for: time, width: width)
    }

    private struct Placement: Identifiable {
        let clip: VideoClip
        let x: Double
        let width: Double
        let lane: Int
        var id: UUID { clip.id }
    }

    private func placements(width: Double) -> [Placement] {
        var ends: [Double] = []
        return review.savedClips.filter { $0.range.end >= scale.lower && $0.range.start <= scale.upper }.map { clip in
            let x = min(position(clip.range.start, width: width), max(0, width - 12))
            let blockWidth = min(max(12, position(clip.range.end, width: width) - x), width - x)
            let lane = ends.firstIndex { $0 + 3 <= x } ?? ends.count
            if lane == ends.count { ends.append(x + blockWidth) }
            else { ends[lane] = x + blockWidth }
            return Placement(clip: clip, x: x, width: blockWidth, lane: lane)
        }
    }
}
