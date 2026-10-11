import SwiftUI

private struct PlaybackFocusKey: FocusedValueKey {
    typealias Value = PlaybackController
}

private struct ClipReviewFocusKey: FocusedValueKey { typealias Value = ClipReviewController }
private struct ClipTextFocusKey: FocusedValueKey { typealias Value = Bool }

extension FocusedValues {
    var isEditingClipText: Bool? {
        get { self[ClipTextFocusKey.self] }
        set { self[ClipTextFocusKey.self] = newValue }
    }
    var clipReview: ClipReviewController? {
        get { self[ClipReviewFocusKey.self] }
        set { self[ClipReviewFocusKey.self] = newValue }
    }
    var playback: PlaybackController? {
        get { self[PlaybackFocusKey.self] }
        set { self[PlaybackFocusKey.self] = newValue }
    }
}

struct PlaybackCommands: Commands {
    @FocusedValue(\.playback) private var playback
    @FocusedValue(\.clipReview) private var review
    @FocusedValue(\.isEditingClipText) private var isEditingText

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Video…") {
                if let review, let playback { review.request(playback.openVideo) }
                else { playback?.openVideo() }
            }
                .keyboardShortcut("o")
                .disabled(playback == nil)
            if let playback, let history = playback.history {
                Menu("Recent Videos") {
                    RecentVideoItems(playback: playback, history: history)
                }
            }
            Button("Back to Workspace") {
                if let review, let playback { review.request(playback.returnToWorkspace) }
                else { playback?.returnToWorkspace() }
            }
                .keyboardShortcut("[")
                .disabled(playback == nil || (playback?.filename == nil && playback?.isLoading != true))
        }
        CommandMenu("Playback") {
            if let playback {
                WorkspacePlaybackCommands(playback: playback, isEditingText: isEditingText == true)
            } else {
                Button("Play / Pause") {}.disabled(true)
            }
        }
        CommandMenu("Clips") {
            if let review { ClipReviewCommands(review: review, playback: review.playback, isEditingText: isEditingText == true) }
        }
    }
}

private struct ClipReviewCommands: View {
    @ObservedObject var review: ClipReviewController
    @ObservedObject var playback: PlaybackController
    let isEditingText: Bool

    var body: some View {
        Group {
            Button("Mark Clip In", action: review.markIn).keyboardShortcut("i", modifiers: []).disabled(isEditingText)
            Button("Mark Clip Out", action: review.markOut).keyboardShortcut("o", modifiers: []).disabled(isEditingText)
            Button("New Clip", action: review.newClip).keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Deselect Clip", action: review.clear).keyboardShortcut(.escape, modifiers: [])
                .disabled(review.draft == nil)
            Button(review.isSaved ? "Delete Selected Clip" : "Clear Clip Selection", action: review.deleteSelection)
                .keyboardShortcut(.delete, modifiers: []).disabled(review.draft == nil || isEditingText)
            Button(playback.loopRange == nil ? "Loop Selected Clip" : "Stop Looping") {
                review.setLoop(playback.loopRange == nil)
            }.keyboardShortcut("r", modifiers: []).disabled(!review.validRange || isEditingText)
        }.disabled(!playback.isReady || playback.isLoading)
    }
}

private struct WorkspacePlaybackCommands: View {
    @ObservedObject var playback: PlaybackController
    let isEditingText: Bool

    var body: some View {
        Group {
            Button(playback.isPlaying ? "Pause" : "Play", action: playback.togglePlayback)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(isEditingText)
            Button("Shuttle Backward") { playback.shuttle(-1) }
                .keyboardShortcut("j", modifiers: [])
                .disabled(isEditingText)
            Button("Pause", action: playback.pause)
                .keyboardShortcut("k", modifiers: [])
                .disabled(isEditingText)
            Button("Shuttle Forward") { playback.shuttle(1) }
                .keyboardShortcut("l", modifiers: [])
                .disabled(isEditingText)
            Button("Previous Frame") { playback.stepFrame(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!playback.canStepBackward || isEditingText)
            Button("Next Frame") { playback.stepFrame(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!playback.canStepForward || isEditingText)
            Divider()
            ForEach(Array(PlaybackController.speeds.enumerated()), id: \.offset) { index, speed in
                Button("\(speed.formatted())× Speed") { playback.setSpeed(speed) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
        }
        .disabled(!playback.isReady || playback.isLoading)
    }
}
