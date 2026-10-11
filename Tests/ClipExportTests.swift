import AVFoundation
import Combine
import Foundation

@MainActor
enum ClipExportTests {
    static func run(fixture: URL) async throws {
        let sourceBefore = try Data(contentsOf: fixture)
        let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ayeneh-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: destination) }
        let videoID = UUID()
        let parent = ReviewOption(name: "Forehand")
        let child = ReviewOption(name: "Fast / incoming", parentID: parent.id)
        let assessment = ReviewOption(name: "Good")
        let template = ReviewTemplate(ownerID: UUID(), name: "Review", clipTypes: [parent, child], assessments: [assessment])
        let first = VideoClip(videoID: videoID, range: .init(start: 1.2, end: 1.8), title: "../Shot: one",
                              templateID: template.id, typeID: child.id, assessmentID: assessment.id, note: "Keep the follow-through")
        let second = VideoClip(videoID: videoID, range: .init(start: 2.2, end: 3.2))
        let snapshot = ClipExportSnapshot(sourceURL: fixture, videoID: videoID, clips: [first, second], templates: [template])
        assert(snapshot.typePath(for: first) == ["Forehand", "Fast / incoming"])
        assert(ClipExportSnapshot.safeComponent("../\\:\n") == "----")
        assert(ClipExportSnapshot.safeComponent("..") == "Untitled")
        assert(ClipExportSnapshot.safeComponent(String(repeating: "🎾", count: 100)).utf8.count <= 140)
        assert(snapshot.relativePath(for: first, organized: true, groupAssessments: true).hasPrefix("Forehand/Fast - incoming/Good/"))
        var duplicate = first
        duplicate.id = UUID()
        assert(snapshot.relativePath(for: first, organized: false, groupAssessments: false) != snapshot.relativePath(for: duplicate, organized: false, groupAssessments: false))

        let exporter = ClipExportController()
        exporter.start(snapshot: snapshot, destination: destination, sessionName: "Session", organized: true, groupAssessments: true)
        try await waitForExport(exporter)
        assert(exporter.errorMessage == nil, exporter.errorMessage ?? "")
        assert(exporter.completedCount == 2 && exporter.progress == 1)
        let folder = exporter.outputFolder!
        let manifest = try readManifest(folder)
        assert(manifest.status == "completed" && manifest.clips.count == 2)
        assert(manifest.clips[0].clip.note == first.note && manifest.clips[0].assessment == "Good")
        assert(manifest.clips[1].typePath == ["Uncategorized"])
        let exportedFirst = folder.appendingPathComponent(manifest.clips[0].relativeFile)
        let exportedAsset = AVURLAsset(url: exportedFirst)
        let duration = try await exportedAsset.load(.duration).seconds
        assert(abs(duration - first.range.duration) < 1 / 30.0 + 0.005, "Unexpected duration \(duration)")
        let video = try await exportedAsset.loadTracks(withMediaType: .video).first!
        let size = try await video.load(.naturalSize)
        assert(size.width == 320 && size.height == 180)
        // Compare the actual decoded first frame against the requested source frame.
        let sourceRed = try await redChannel(AVURLAsset(url: fixture), time: first.range.start)
        let exportRed = try await redChannel(exportedAsset, time: 0)
        assert(abs(sourceRed - exportRed) < 5, "Export started at the wrong source frame")
        let sourceLast = try await redChannel(AVURLAsset(url: fixture), time: first.range.end - 1 / 30.0)
        let exportLast = try await redChannel(exportedAsset, time: first.range.duration - 1 / 30.0)
        assert(abs(sourceLast - exportLast) < 5, "Export ended at the wrong source frame")

        // A second export uses a new directory and leaves existing media/index untouched.
        let indexBefore = try Data(contentsOf: folder.appendingPathComponent("clips.json"))
        exporter.start(snapshot: snapshot, destination: destination, sessionName: "Session", organized: false, groupAssessments: false)
        try await waitForExport(exporter)
        assert(exporter.outputFolder!.lastPathComponent == "Session (2)")
        let indexAfter = try Data(contentsOf: folder.appendingPathComponent("clips.json"))
        assert(indexAfter == indexBefore)
        let flat = try readManifest(exporter.outputFolder!)
        assert(flat.clips.allSatisfy { !$0.relativeFile.contains("/") })

        // Cancel between clips: completed media remains and the index reflects partial results.
        let cancellation = exporter.$completedCount.dropFirst().sink { count in if count == 1 { exporter.cancel() } }
        exporter.start(snapshot: snapshot, destination: destination, sessionName: "Partial", organized: true, groupAssessments: true)
        try await waitForExport(exporter)
        cancellation.cancel()
        assert(exporter.wasCancelled && exporter.completedCount == 1)
        let partial = try readManifest(exporter.outputFolder!)
        assert(partial.status == "cancelled" && partial.clips.count == 1)
        assert(mp4Files(in: exporter.outputFolder!).count == 1)

        // Invalid source ranges fail before any output directory is created.
        var invalid = first
        invalid.range.end = 20
        exporter.start(snapshot: .init(sourceURL: fixture, videoID: videoID, clips: [invalid], templates: [template]),
                       destination: destination, sessionName: "Invalid", organized: true, groupAssessments: true)
        try await waitForExport(exporter)
        assert(exporter.errorMessage != nil && exporter.outputFolder == nil)

        // Portrait footage with an audio track retains both presentation geometry and sound.
        let portrait = destination.appendingPathComponent("portrait.mov")
        try await PlaybackSmokeTests.makeVideo(at: portrait, portrait: true)
        let withAudio = try await addAudio(to: portrait, in: destination)
        let audioSnapshot = ClipExportSnapshot(sourceURL: withAudio, videoID: videoID, clips: [first], templates: [template])
        exporter.start(snapshot: audioSnapshot, destination: destination, sessionName: "Portrait", organized: false, groupAssessments: false)
        try await waitForExport(exporter)
        assert(exporter.errorMessage == nil, exporter.errorMessage ?? "")
        let audioManifest = try readManifest(exporter.outputFolder!)
        let audioAsset = AVURLAsset(url: exporter.outputFolder!.appendingPathComponent(audioManifest.clips[0].relativeFile))
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        assert(audioTracks.count == 1)
        let portraitTrack = try await audioAsset.loadTracks(withMediaType: .video).first!
        let natural = try await portraitTrack.load(.naturalSize)
        let transform = try await portraitTrack.load(.preferredTransform)
        let presented = CGRect(origin: .zero, size: natural).applying(transform)
        assert(abs(presented.width) == 180 && abs(presented.height) == 320)
        assert(FileManager.default.fileExists(atPath: fixture.path))
        let sourceAfter = try Data(contentsOf: fixture)
        assert(sourceBefore == sourceAfter)
        print("PASS: real MP4 exports, precise decoded start/duration, resolution, portrait/audio preservation, hierarchical/flat paths, metadata, no overwrite, cancellation, invalid ranges")
    }

    private static func waitForExport(_ exporter: ClipExportController) async throws {
        for _ in 0..<1500 {
            if !exporter.isRunning { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        exporter.cancel()
        throw NSError(domain: "ExportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out exporting"])
    }

    private static func readManifest(_ folder: URL) throws -> ClipExportManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ClipExportManifest.self, from: Data(contentsOf: folder.appendingPathComponent("clips.json")))
    }

    private static func mp4Files(in folder: URL) -> [URL] {
        (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "mp4" }
    }

    private static func redChannel(_ asset: AVAsset, time: Double) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000)).image
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Int(rgba[0])
    }

    private static func addAudio(to video: URL, in directory: URL) async throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 4)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 44100)) * 0.1 }
        let wav = directory.appendingPathComponent("tone.wav")
        do {
            let audioFile = try AVAudioFile(forWriting: wav, settings: format.settings)
            try audioFile.write(from: buffer)
        }
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: wav)
        defer { withExtendedLifetime((videoAsset, audioAsset)) {} }
        let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first!
        let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first!
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try videoTrack.insertTimeRange(.init(start: .zero, duration: videoDuration), of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try audioTrack.insertTimeRange(.init(start: .zero, duration: CMTimeMinimum(videoDuration, audioDuration)), of: sourceAudio, at: .zero)
        let output = directory.appendingPathComponent("portrait-audio.mov")
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        session.outputURL = output
        session.outputFileType = .mov
        if #available(macOS 15.0, *) {
            try await session.export(to: output, as: .mov)
        } else {
            try await legacyExport(session)
        }
        return output
    }

    @available(macOS, introduced: 14.0, deprecated: 15.0)
    private static func legacyExport(_ session: AVAssetExportSession) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else { throw session.error! }
    }
}
