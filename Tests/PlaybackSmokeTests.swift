// Run using Tests/run-smoke-tests.sh. Fixture media stays in the temporary directory.
import AppKit
import AVFoundation

@main
struct PlaybackSmokeTests {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        try ReviewTemplateTests.run()
        let fixture = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ayeneh-smoke-\(UUID().uuidString).mov")
        try await makeVideo(at: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let full = TimelineScale.full(duration: 100)
        assert(full.time(at: 50, width: 100) == 50)
        assert(full.time(at: -10, width: 100) == 0)
        assert(full.time(at: 110, width: 100) == 100)
        assert(full.time(at: 20, width: 0) == 0)
        let fine = TimelineScale.fine(duration: 100, center: 50)
        assert(fine.lower == 45 && fine.upper == 55)
        assert(TimelineScale.fine(duration: 100, center: 0).lower == 0)
        assert(TimelineScale.fine(duration: 100, center: 100).upper == 100)
        assert(fine.position(for: 50, width: 100) == 50)
        // Zoom keeps the selected time under the pointer, even away from the center.
        for fraction in [0.0, 0.1, 0.25, 0.75, 0.9, 1.0] {
            let time = fraction * 100
            let anchored = TimelineScale.fine(duration: 100, center: time, anchorFraction: fraction)
            assert(abs(anchored.position(for: time, width: 100) - fraction * 100) < 0.0001)
            let halfway = TimelineScale(lower: anchored.lower / 2, upper: (100 + anchored.upper) / 2)
            assert(abs(halfway.position(for: time, width: 100) - fraction * 100) < 0.0001)
        }
        assert(TimelineScale.fine(duration: 0, center: 0).position(for: 0, width: 100) == 0)
        let clippingScale = TimelineScale.zoomed(duration: 1800, span: 20, center: 600)
        assert(clippingScale.lower == 590 && clippingScale.upper == 610)
        let handleX = clippingScale.position(for: 598, width: 800)
        assert(clippingScale.time(at: handleX, width: 800) == 598)
        let finer = TimelineScale.zoomed(duration: 1800, span: clippingScale.span / 10, center: 598, anchorFraction: handleX / 800)
        assert(abs(finer.position(for: 598, width: 800) - handleX) < 0.0001)
        assert(TimelineScale.zoomed(duration: 4, span: 10, center: 2).span == 4)

        let playback = PlaybackController()
        defer { playback.shutdown() }
        playback.load(fixture)
        try await wait { playback.isReady && !playback.isLoading }
        assert(abs(playback.duration - 4) < 0.1)
        assert(playback.player.rate == 0)
        assert(playback.canStepForward && playback.canStepBackward)

        for speed in PlaybackController.speeds {
            playback.togglePlayback()
            playback.setSpeed(speed)
            try await wait { playback.usesSeekPlayback || abs(playback.player.rate - speed) < 0.01 }
            playback.pause()
        }
        playback.seek(to: 1)
        try await wait { abs(playback.player.currentTime().seconds - 1) < 0.02 }
        playback.stepFrame(1)
        try await wait { playback.player.currentTime().seconds > 1.02 }
        playback.stepFrame(-1)
        try await wait { abs(playback.player.currentTime().seconds - 1) < 0.02 }

        playback.beginScrubbing()
        for index in 0..<30 { playback.seek(to: Double(index) / 10) }
        playback.endScrubbing(at: 2)
        try await wait { abs(playback.player.currentTime().seconds - 2) < 0.02 }
        assert(playback.player.rate == 0)

        playback.togglePlayback()
        playback.setSpeed(0.25)
        try await wait { playback.player.rate > 0 }
        playback.beginScrubbing()
        playback.endScrubbing(at: 1)
        try await wait { playback.player.rate == 0.25 && playback.player.currentTime().seconds >= 1 }
        playback.pause()

        // First click is 2×, repeated clicks cycle; opposite direction restores normal 1×.
        assert(PlaybackController.shuttleSpeeds == [1, 2, 3, 4])
        assert(!PlaybackController.speeds.contains(0.5))
        playback.seek(to: 2)
        try await wait { abs(playback.player.currentTime().seconds - 2) < 0.02 }
        for expected: Float in [2, 3, 4, 1, 2] {
            playback.shuttle(1)
            assert(playback.direction == 1 && playback.speed == expected)
        }
        playback.shuttle(-1)
        assert(playback.direction == 1 && playback.speed == 1)
        playback.shuttle(-1)
        assert(playback.direction == -1 && playback.speed == 2)
        try await wait { playback.currentTime < 1.9 }
        playback.shuttle(1)
        assert(playback.direction == 1 && playback.speed == 1)
        playback.shuttle(-1)
        assert(playback.direction == -1 && playback.speed == 2)
        playback.beginScrubbing()
        assert(!playback.isPlaying)
        playback.endScrubbing(at: 2)
        try await wait { playback.isPlaying && playback.currentTime < 1.9 }
        assert(playback.direction == -1 && playback.speed == 2)
        playback.pause()
        assert(playback.speed == 1 && playback.direction == 1 && playback.player.defaultRate == 1)
        let pausedTime = playback.currentTime
        try await Task.sleep(for: .milliseconds(200))
        assert(abs(playback.currentTime - pausedTime) < 0.1)
        playback.shuttle(1)
        assert(playback.direction == 1 && playback.speed == 2)
        playback.togglePlayback()
        assert(!playback.isPlaying && playback.speed == 1 && playback.direction == 1)
        playback.togglePlayback()
        assert(playback.speed == 1 && playback.direction == 1)
        playback.shuttle(-1)
        assert(playback.direction == -1 && playback.speed == 2)
        playback.togglePlayback()
        assert(!playback.isPlaying && playback.speed == 1 && playback.direction == 1)
        playback.setSpeed(4)
        playback.togglePlayback()
        assert(playback.speed == 1 && playback.direction == 1)
        playback.stepFrame(-1)
        assert(!playback.isPlaying)
        playback.seek(to: 0.2)
        try await wait { abs(playback.player.currentTime().seconds - 0.2) < 0.02 }
        playback.shuttle(-1)
        assert(playback.direction == -1 && playback.speed == 2)
        try await wait { !playback.isPlaying && playback.currentTime < 0.05 }
        playback.shuttle(1)
        playback.pause()

        playback.seek(to: playback.duration)
        try await wait { playback.currentTime >= playback.duration - 0.02 }
        playback.togglePlayback()
        try await wait { playback.player.rate > 0 && playback.player.currentTime().seconds < 1 }
        playback.pause()

        // A failed replacement preserves the loaded asset.
        let originalItem = playback.player.currentItem
        playback.load(URL(fileURLWithPath: "/private/tmp/ayeneh-missing-\(UUID().uuidString).mov"))
        try await wait { !playback.isLoading && playback.errorMessage != nil }
        assert(playback.player.currentItem === originalItem)
        playback.errorMessage = nil

        // Cancel a stale import and stale seeks by replacing the current item.
        playback.load(URL(fileURLWithPath: "/private/tmp/ayeneh-missing.mov"))
        playback.load(fixture)
        try await wait { playback.isReady && !playback.isLoading && playback.player.currentItem !== originalItem }
        assert(playback.errorMessage == nil)
        playback.seek(to: 3)
        playback.shutdown()
        try await Task.sleep(for: .milliseconds(200))
        assert(playback.player.currentItem == nil && playback.currentTime == 0)
        print("PASS: timeline mapping, import, rates, first-click 2× in both directions, opposite-button 1×, play/pause rate resets, shuttle boundaries, frame stepping, coalesced seeks, scrub resume, restart, failed/stale imports, cleanup")
        try await ClipReviewTests.run(fixture: fixture)
        try await ClipExportTests.run(fixture: fixture)
        try await WorkspaceHistoryTests.run(fixture: fixture)
    }

    @MainActor
    static func wait(_ predicate: () -> Bool, file: String = #fileID, line: Int = #line) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "SmokeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for playback state at \(file):\(line)"])
    }

    static func makeVideo(at url: URL, metadata: [AVMetadataItem] = [], portrait: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = metadata
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180
        ])
        if portrait { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<120 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error! }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            let result = CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard result == kCVReturnSuccess, let buffer else { fatalError("Pixel buffer creation failed") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<180 {
                for x in 0..<320 {
                    let offset = y * stride + x * 4
                    bytes[offset] = 255
                    bytes[offset + 1] = UInt8(frame * 2)
                    bytes[offset + 2] = UInt8(x % 256)
                    bytes[offset + 3] = UInt8(y)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error!
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
    }
}
