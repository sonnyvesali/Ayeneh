import Foundation

@MainActor
enum ClipReviewTests {
    static func run(fixture: URL) async throws {
        let suite = "AyenehClipTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let templates = ReviewTemplateStore(defaults: defaults)
        let history = WorkspaceHistoryStore(defaults: defaults)
        let store = ClipStore(profileID: templates.profileID, defaults: defaults)
        let playback = PlaybackController(history: history)
        defer { playback.shutdown() }
        let review = ClipReviewController(playback: playback, store: store, templates: templates)
        playback.load(fixture)
        try await PlaybackSmokeTests.wait { playback.isReady && !playback.isLoading && playback.currentVideoID != nil }
        let videoID = playback.currentVideoID!
        var template = ReviewTemplate.draft(ownerID: templates.profileID)
        template.name = "Session review"
        let root = ReviewOption(name: "Forehand")
        let child = ReviewOption(name: "Fast", parentID: root.id)
        template.clipTypes = [root, child]
        template.assessments = [ReviewOption(name: "Good"), ReviewOption(name: "Needs work")]
        template = try templates.save(template)
        history.assignReviewTemplate(template.id, to: videoID)

        review.drawRange(from: 1.6, to: 1)
        assert(review.draft?.range == ClipRange(start: 1, end: 1.6))
        assert(store.clips.count == 1 && review.isSaved && review.saveStatus == .saved)
        assert(store.clips[0].typeID == nil && store.clips[0].assessmentID == nil)
        assert(review.focusRequest == review.draft?.range)
        assert(playback.loopRange == review.draft?.range)
        review.draft?.typeID = child.id
        assert(store.clips[0].typeID == child.id) // Associations save immediately.
        review.draft?.assessmentID = template.assessments[0].id
        assert(store.clips[0].assessmentID == template.assessments[0].id)
        review.draft?.note = "  Early contact  "
        assert(review.saveStatus == .saving)
        try await PlaybackSmokeTests.wait { review.saveStatus == .saved }
        let saved = store.clips[0]
        assert(saved.note == "Early contact" && review.typeLabel(for: saved) == "Forehand › Fast")
        assert(review.draft?.note == "  Early contact  ") // Typing retains its whitespace.
        let reopened = ClipStore(profileID: templates.profileID, defaults: defaults)
        assert(reopened.clips == store.clips)
        assert(ClipStore(profileID: UUID(), defaults: defaults).clips.isEmpty)
        assert(store.clips(for: UUID()).isEmpty)

        // Draw another overlapping range; last-used categories are reused.
        review.drawRange(from: 1.3, to: 1.9)
        assert(review.draft?.typeID == child.id && review.draft?.assessmentID == template.assessments[0].id)
        assert(store.clips.count == 2 && store.clips[0].id != store.clips[1].id)
        let secondID = review.draft!.id
        review.draft?.note = "Change before switching"
        review.select(saved)
        assert(store.clips.first { $0.id == secondID }?.note == "Change before switching")
        assert(review.draft?.id == saved.id)
        review.setLoop(false)
        review.setBoundary(start: true, time: 1.1)
        review.focusClip()
        assert(playback.loopRange == nil) // Refining respects an explicitly disabled loop.
        assert(store.clips.count == 2 && store.clips.first { $0.id == saved.id }?.range.start == 1.1)
        template.clipTypes[1].name = "Fast incoming"
        template.clipTypes[1].isArchived = true
        _ = try templates.save(template)
        assert(review.typeLabel(for: review.draft!) == "Forehand › Fast incoming")
        assert(review.color(for: saved) == .blue && review.assessmentColor(for: saved) == .gray)
        template.color = .purple
        _ = try templates.save(template)
        assert(review.color(for: saved) == .blue) // Top-level type colors are explicit, independent of template color.
        var templateOnly = saved
        templateOnly.typeID = nil
        assert(review.color(for: templateOnly) == .purple)
        template.clipTypes[0].color = .orange
        template.assessments[0].color = .green
        _ = try templates.save(template)
        assert(review.color(for: saved) == .orange && review.assessmentColor(for: saved) == .green)
        template.clipTypes[1].color = .pink
        _ = try templates.save(template)
        assert(review.color(for: saved) == .pink) // Archived option references still resolve their color.
        let tooltip = review.hoverDetails(for: saved)
        assert(tooltip.contains("Forehand › Fast incoming") && tooltip.contains("Assessment: Good"))
        assert(tooltip.contains("Early contact") && tooltip.contains("0:01.000") && tooltip.contains("0:00.600"))
        var uncategorized = saved
        uncategorized.templateID = nil
        uncategorized.typeID = nil
        uncategorized.assessmentID = nil
        assert(review.color(for: uncategorized) == .blue && review.assessmentColor(for: uncategorized) == nil)
        assert(review.hoverDetails(for: uncategorized).contains("Type: Uncategorized"))

        let focused = TimelineScale.focused(duration: 22, range: ClipRange(start: 8, end: 13))
        assert(focused.span == 10 && focused.lower == 5.5 && focused.upper == 15.5)
        assert(TimelineScale.focused(duration: 22, range: ClipRange(start: 0, end: 1)).lower == 0)
        assert(TimelineScale.focused(duration: 22, range: ClipRange(start: 21, end: 22)).upper == 22)
        review.setLoop(true)
        review.deselectIfOutside(at: 1.3)
        assert(review.draft != nil && playback.loopRange != nil)
        review.draft?.note = "Saved when clicking away"
        review.deselectIfOutside(at: 2)
        assert(review.draft == nil && review.focusRequest == nil && playback.loopRange == nil)
        assert(store.clips.first { $0.id == saved.id }?.note == "Saved when clicking away")
        let tinyFocus = TimelineScale.focused(duration: 22, range: ClipRange(start: 8, end: 8.2))
        assert(abs(tinyFocus.span - 0.4) < 0.0001)
        let widthFraction = 0.2 / tinyFocus.span
        assert(widthFraction > 0.49 && widthFraction < 0.51)
        review.select(saved)
        assert(review.draft?.range.start == 1.1) // Stale selections don't overwrite newer edits.
        assert(review.focusRequest != nil)
        assert(playback.loopRange == review.draft?.range)
        assert(ClipRange(start: 1.6 - 0.02, end: 1.6).isValid(for: 4))

        // Forward and reverse loops wrap, retain their rate, and stay inside the range.
        playback.pause()
        playback.seek(to: 1.15)
        try await PlaybackSmokeTests.wait { abs(playback.player.currentTime().seconds - 1.15) < 0.02 }
        review.setLoop(true)
        playback.togglePlayback()
        playback.setSpeed(2)
        var wraps = 0
        var previous = playback.currentTime
        for _ in 0..<90 {
            try await Task.sleep(for: .milliseconds(20))
            if previous - playback.currentTime > 0.2 { wraps += 1 }
            assert(playback.currentTime >= 1.08 && playback.currentTime <= 1.65)
            previous = playback.currentTime
        }
        assert(wraps >= 2 && playback.speed == 2 && playback.loopRange != nil)
        playback.pause()
        playback.seek(to: 1.3)
        try await PlaybackSmokeTests.wait { abs(playback.player.currentTime().seconds - 1.3) < 0.02 }
        playback.shuttle(-1)
        var reverseWraps = 0
        previous = playback.currentTime
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(20))
            if playback.currentTime - previous > 0.2 { reverseWraps += 1 }
            assert(playback.currentTime >= 1.08 && playback.currentTime <= 1.65)
            previous = playback.currentTime
        }
        assert(reverseWraps >= 1 && playback.direction == -1 && playback.speed == 2)
        playback.pause()
        playback.seek(to: 0)
        try await PlaybackSmokeTests.wait { abs(playback.currentTime - 1.1) < 0.02 }
        playback.stepFrame(-1)
        try await Task.sleep(for: .milliseconds(150))
        assert(playback.currentTime >= 1.09)
        playback.beginScrubbing()
        playback.seekFromTimeline(to: 3)
        playback.endScrubbing(at: 3)
        try await PlaybackSmokeTests.wait { abs(playback.currentTime - 3) < 0.02 }
        assert(playback.loopRange == nil)

        // Invalid ranges cannot persist, including nonfinite and out-of-video bounds.
        for range in [ClipRange(start: 2, end: 1), ClipRange(start: 0, end: .infinity), ClipRange(start: -1, end: 1), ClipRange(start: 0, end: 5)] {
            var invalid = saved
            invalid.range = range
            do { _ = try store.save(invalid, duration: playback.duration); assertionFailure("Invalid range saved") }
            catch is ReviewTemplateStore.ValidationError { }
        }
        review.removeSelected()
        assert(store.clips.count == 1 && review.draft == nil)
        assert(ClipStore(profileID: templates.profileID, defaults: defaults).clips.count == 1)
        playback.returnToWorkspace()
        assert(playback.loopRange == nil && review.draft == nil)
        playback.load(fixture)
        try await PlaybackSmokeTests.wait { playback.isReady && !playback.isLoading && playback.currentVideoID == videoID }
        assert(review.savedClips.count == 1)
        review.newClip()
        assert(review.draft != nil && store.clips.count == 2)
        review.setLoop(true)
        review.deleteSelection()
        assert(review.draft == nil && playback.loopRange == nil && store.clips.count == 1)

        // An incomplete I mark stays temporary until O produces a valid range.
        playback.seek(to: 0.2)
        try await PlaybackSmokeTests.wait { abs(playback.currentTime - 0.2) < 0.02 }
        review.markIn()
        assert(review.draft != nil && !review.isSaved && review.saveStatus == .waitingForRange)
        assert(review.focusRequest == nil && store.clips.count == 1)
        review.deleteSelection()
        assert(review.draft == nil && store.clips.count == 1)
        review.markIn()
        playback.seek(to: 0.7)
        try await PlaybackSmokeTests.wait { abs(playback.currentTime - 0.7) < 0.02 }
        review.markOut()
        assert(review.isSaved && review.focusRequest == review.draft?.range && store.clips.count == 2)
        assert(playback.loopRange == review.draft?.range)
        let markedID = review.draft!.id
        review.draft?.title = "Last title before leaving"
        review.request(playback.returnToWorkspace)
        assert(review.draft == nil && review.focusRequest == nil)
        assert(ClipStore(profileID: templates.profileID, defaults: defaults).clips.first { $0.id == markedID }?.title == "Last title before leaving")
        try await Task.sleep(for: .milliseconds(400))
        assert(store.clips.count == 2) // Cancelled debounce cannot resurrect a cleared/deleted selection.
        print("PASS: clip ranges/categories, overlap, persistence/profile scope, stable references, autosave/debounce/leave flushing, automatic short-clip focus and click-away deselection, forward/reverse looping, frame/scrub bounds, deletion and reopening")
    }
}
