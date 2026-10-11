 import SwiftUI

struct PlaybackControls: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject var review: ClipReviewController

    var body: some View {
        VStack(spacing: 12) {
            VideoTimeline(playback: playback, review: review)
            HStack(spacing: 12) {
                Text("\(timeLabel(playback.currentTime)) / \(timeLabel(playback.duration))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 10) {
                    shuttleButton(direction: -1)
                    Button { playback.togglePlayback() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 28, height: 24)
                    }
                    .help("Play or pause (Space)")
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                    shuttleButton(direction: 1)
                }
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.top, 8)
                Spacer()
                Picker("Speed", selection: Binding(get: { playback.speed }, set: playback.setSpeed)) {
                    ForEach(PlaybackController.speeds, id: \.self) { speed in
                        Text("\(speed.formatted())×").tag(speed)
                    }
                }
                .frame(width: 130)
                .help("Playback speed (⌘1–⌘5)")
            }
            .disabled(!playback.isReady || playback.isLoading)
        }
        .padding(16)
        .background(.bar)
    }

    private func shuttleButton(direction: Int) -> some View {
        let selected = playback.direction == direction
        let title = direction < 0 ? "Backward" : "Forward"
        let shortcut = direction < 0 ? "J" : "L"
        return Button { playback.shuttle(direction) } label: {
            Image(systemName: direction < 0 ? "backward.fill" : "forward.fill")
                .frame(width: 28, height: 24)
        }
        .overlay(alignment: .top) {
            if selected, playback.speed != 1 {
                Text("\(playback.speed.formatted())×")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                    .offset(y: -9)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeOut(duration: 0.16), value: selected && playback.speed != 1)
        .help("\(title): start at 2×; repeat for 3×, 4×, then 1×. Opposite direction resets to normal playback (\(shortcut)).")
        .accessibilityLabel("Cycle \(title.lowercased()) playback speed")
        .accessibilityValue(selected ? "\(playback.speed.formatted()) times, \(playback.isPlaying ? "playing" : "paused")" : playback.speed > 1 ? "Returns to normal playback" : "Starts at 2 times")
    }
}
