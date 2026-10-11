import AVFoundation
import AppKit
import Foundation

@MainActor
enum WorkspaceHistoryTests {
    static func run(fixture: URL) async throws {
        let suite = "AyenehHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ayeneh-previews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let history = WorkspaceHistoryStore(defaults: defaults, cacheDirectory: cache)
        assert(history.videos.isEmpty && history.lastVideo == nil)

        let playback = PlaybackController(history: history)
        playback.load(fixture)
        try await PlaybackSmokeTests.wait { playback.isReady && !playback.isLoading }
        if let error = playback.errorMessage { throw NSError(domain: "HistoryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        assert(history.videos.count == 1)
        let id = history.videos[0].id
        let templateID = UUID()
        history.assignReviewTemplate(templateID, to: id)
        let preview = await history.preview(for: history.videos[0])
        assert(preview.image != nil && !preview.unavailable)
        assert(history.videos[0].details?.width == 320 && history.videos[0].details?.height == 180)
        assert(history.videos[0].details?.codec == "H.264")
        assert(history.videos[0].details?.capturedAt == nil && history.videos[0].details?.location == nil)
        playback.seek(to: 1.5)
        try await PlaybackSmokeTests.wait { abs(playback.player.currentTime().seconds - 1.5) < 0.02 }
        playback.pause()
        playback.shutdown()

        // A fresh store and controller model the next launch.
        let reopenedHistory = WorkspaceHistoryStore(defaults: defaults, cacheDirectory: cache)
        assert(reopenedHistory.lastVideoID == id)
        assert(reopenedHistory.videos[0].reviewTemplateID == templateID)
        assert(abs(reopenedHistory.lastVideo!.position - 1.5) < 0.02)
        let reopened = PlaybackController(history: reopenedHistory)
        reopened.restoreLastVideo()
        try await PlaybackSmokeTests.wait { reopened.isReady && !reopened.isLoading }
        assert(abs(reopened.player.currentTime().seconds - 1.5) < 0.02)
        assert(!reopened.isPlaying && reopened.player.rate == 0 && reopened.speed == 1)
        reopened.restoreLastVideo() // Restoration runs once per workspace, never resets active playback.
        assert(!reopened.isLoading)

        // Reopening the same file keeps one entry and restores its current saved position.
        reopened.seek(to: 2)
        try await PlaybackSmokeTests.wait { abs(reopened.player.currentTime().seconds - 2) < 0.02 }
        reopened.returnToWorkspace()
        assert(reopened.filename == nil && !reopened.isReady && !reopened.isPlaying)
        assert(abs(reopenedHistory.videos[0].position - 2) < 0.02)
        let homeHistory = WorkspaceHistoryStore(defaults: defaults, cacheDirectory: cache)
        assert(!homeHistory.restoresVideoOnLaunch)
        let home = PlaybackController(history: homeHistory)
        home.restoreLastVideo()
        assert(!home.isLoading && home.filename == nil)
        reopened.restoreLastVideo()
        assert(!reopened.isLoading) // Back must not immediately auto-open the last video again.
        reopened.openRecent(reopenedHistory.videos[0])
        try await PlaybackSmokeTests.wait { !reopened.isLoading }
        assert(reopenedHistory.videos.count == 1 && reopenedHistory.videos[0].id == id)
        assert(reopenedHistory.restoresVideoOnLaunch)
        assert(reopenedHistory.videos[0].reviewTemplateID == templateID)
        assert(abs(reopened.player.currentTime().seconds - 2) < 0.02)
        reopened.load(fixture)
        reopened.returnToWorkspace()
        try await Task.sleep(for: .milliseconds(200))
        assert(reopened.filename == nil && !reopened.isLoading)

        // Position writes don't steal the last-opened identity or reorder the list.
        let otherID = try reopenedHistory.remember(fixture, replacing: nil, position: 2)
        assert(otherID == id && reopenedHistory.videos.count == 1)
        reopenedHistory.savePosition(.nan, for: id)
        assert(reopenedHistory.videos[0].position.isFinite)
        reopened.shutdown()

        // A deleted file remains recoverable through Locate/Remove instead of disappearing.
        try FileManager.default.removeItem(at: fixture)
        let missing = PlaybackController(history: reopenedHistory)
        missing.restoreLastVideo()
        try await PlaybackSmokeTests.wait { missing.unavailableVideo != nil }
        assert(!missing.isReady && reopenedHistory.videos.count == 1)
        let offlinePreview = await reopenedHistory.preview(for: reopenedHistory.videos[0])
        assert(offlinePreview.image != nil && offlinePreview.unavailable)

        // Relocate the missing entry to another selected video, retaining its identity/position.
        let replacement = fixture.deletingPathExtension().appendingPathExtension("replacement.mov")
        try await PlaybackSmokeTests.makeVideo(at: replacement)
        defer { try? FileManager.default.removeItem(at: replacement) }
        missing.load(replacement, restoring: reopenedHistory.videos[0])
        try await PlaybackSmokeTests.wait { missing.isReady && !missing.isLoading }
        assert(missing.unavailableVideo == nil)
        assert(reopenedHistory.videos.count == 1 && reopenedHistory.videos[0].id == id)
        assert(reopenedHistory.videos[0].path == replacement.standardizedFileURL.path)
        assert(reopenedHistory.videos[0].reviewTemplateID == templateID)
        reopenedHistory.assignReviewTemplate(nil, to: id)
        assert(WorkspaceHistoryStore(defaults: defaults, cacheDirectory: cache).videos[0].reviewTemplateID == nil)
        assert(abs(missing.player.currentTime().seconds - 2) < 0.02)
        missing.removeFromHistory(reopenedHistory.videos[0])
        missing.pause()
        missing.shutdown()
        assert(reopenedHistory.videos.isEmpty && reopenedHistory.lastVideo == nil)
        assert(WorkspaceHistoryStore(defaults: defaults, cacheDirectory: cache).videos.isEmpty)
        assert(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("\(id.uuidString).jpg").path))
        try await verifyCaptureMetadata()
        print("PASS: launch-screen/position restoration, back navigation, bookmarked history, thumbnails/cache, embedded metadata, missing-file recovery, relocation, removal")
    }

    static func verifyCaptureMetadata() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ayeneh-metadata-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        try await PlaybackSmokeTests.makeVideo(at: url, metadata: [
            item(.quickTimeMetadataCreationDate, "2026-10-11T10:15:30-05:00"),
            item(.quickTimeMetadataMake, "Apple"),
            item(.quickTimeMetadataModel, "iPhone Test"),
            item(.quickTimeMetadataLocationISO6709, "+37.3317-122.0301+008.000/")
        ], portrait: true)
        let details = try await VideoInspector.details(for: url)
        assert(details.width == 180 && details.height == 320)
        assert(details.capturedAt == VideoInspector.parseCaptureDate("2026-10-11T15:15:30Z"))
        assert(details.device == "iPhone Test")
        assert(details.location == "37.3317° N, 122.0301° W")
        assert(abs(details.frameRate! - 30) < 0.01)
        let data = try await VideoInspector.thumbnail(for: url, duration: details.duration)
        let image = NSImage(data: data!)!
        assert(image.size.height > image.size.width)
        assert(VideoInspector.locationLabel("+91.0000-122.0000/") == nil)
        assert(VideoInspector.locationLabel("invalid") == nil)
        assert(VideoInspector.parseCaptureDate("invalid") == nil)
        assert(VideoInspector.parseCaptureDate("2026-10-11T15:15:30.123Z") != nil)
    }
}
