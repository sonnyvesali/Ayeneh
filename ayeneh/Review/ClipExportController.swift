import AVFoundation
import Combine
import Darwin
import Foundation

struct ClipExportSnapshot {
    let sourceURL: URL
    let videoID: UUID
    let clips: [VideoClip]
    let templates: [ReviewTemplate]

    func typePath(for clip: VideoClip) -> [String] {
        guard let template = templates.first(where: { $0.id == clip.templateID }) else { return ["Uncategorized"] }
        var path: [String] = []
        var current = clip.typeID
        var visited = Set<UUID>()
        while let id = current, visited.insert(id).inserted,
              let option = template.clipTypes.first(where: { $0.id == id }) {
            path.insert(option.name, at: 0)
            current = option.parentID
        }
        return path.isEmpty ? ["Uncategorized"] : path
    }

    func assessment(for clip: VideoClip) -> ReviewOption? {
        templates.first { $0.id == clip.templateID }?.assessments.first { $0.id == clip.assessmentID }
    }

    static func safeComponent(_ name: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let clean = name.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var result = ""
        for character in clean {
            guard result.utf8.count + String(character).utf8.count <= 140 else { break }
            result.append(character)
        }
        return result.isEmpty ? "Untitled" : result
    }

    func relativePath(for clip: VideoClip, organized: Bool, groupAssessments: Bool) -> String {
        var components = organized ? typePath(for: clip).map { Self.safeComponent($0) } : []
        if groupAssessments { components.append(Self.safeComponent(assessment(for: clip)?.name ?? "Not assessed")) }
        let milliseconds = Int64((clip.range.start * 1000).rounded())
        let time = String(format: "%02lldm%02llds%03lld", milliseconds / 60000, (milliseconds / 1000) % 60, milliseconds % 1000)
        components.append("\(Self.safeComponent(clip.title.isEmpty ? "Clip" : clip.title)) — \(time) — \(clip.id.uuidString).mp4")
        return components.joined(separator: "/")
    }
}

struct ClipExportManifest: Codable {
    struct Entry: Codable {
        let clip: VideoClip
        let typePath: [String]
        let assessment: String?
        let relativeFile: String
    }
    var version = 1
    let createdAt: Date
    let sourceFilename: String
    let videoID: UUID
    let templates: [ReviewTemplate]
    let requestedClipIDs: [UUID]
    var status = "exporting"
    var clips: [Entry] = []
    var error: String?
}

@MainActor
final class ClipExportController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var currentTitle = ""
    @Published private(set) var outputFolder: URL?
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var wasCancelled = false
    private var task: Task<Void, Never>?
    private var session: AVAssetExportSession?
    private var cancellationRequested = false

    func start(snapshot: ClipExportSnapshot, destination: URL, sessionName: String,
               organized: Bool, groupAssessments: Bool) {
        guard !isRunning, !snapshot.clips.isEmpty else { return }
        isRunning = true
        cancellationRequested = false
        wasCancelled = false
        progress = 0
        completedCount = 0
        totalCount = snapshot.clips.count
        currentTitle = ""
        outputFolder = nil
        errorMessage = nil
        statusMessage = "Preparing export…"
        // Independent access survives switching or closing the source workspace.
        let sourceAccess = snapshot.sourceURL.startAccessingSecurityScopedResource()
        let destinationAccess = destination.startAccessingSecurityScopedResource()
        task = Task {
            defer {
                if sourceAccess { snapshot.sourceURL.stopAccessingSecurityScopedResource() }
                if destinationAccess { destination.stopAccessingSecurityScopedResource() }
                session = nil
                isRunning = false
                task = nil
            }
            var manifest = ClipExportManifest(createdAt: Date(), sourceFilename: snapshot.sourceURL.lastPathComponent,
                                              videoID: snapshot.videoID, templates: snapshot.templates.filter { template in
                                                  snapshot.clips.contains { $0.templateID == template.id }
                                              },
                                              requestedClipIDs: snapshot.clips.map(\.id))
            var unfinishedFile: URL?
            do {
                let asset = AVURLAsset(url: snapshot.sourceURL)
                let duration = try await asset.load(.duration).seconds
                guard snapshot.clips.allSatisfy({ $0.videoID == snapshot.videoID && $0.range.isValid(for: duration) }) else {
                    throw ExportError("A clip is outside the source video's duration. Check its boundaries before exporting.")
                }
                try checkCancellation()
                let folder = try createFolder(in: destination, named: sessionName)
                outputFolder = folder
                try write(manifest, to: folder)
                for clip in snapshot.clips {
                    try checkCancellation()
                    currentTitle = clip.displayTitle
                    statusMessage = "Exporting \(completedCount + 1) of \(totalCount)"
                    let relative = snapshot.relativePath(for: clip, organized: organized, groupAssessments: groupAssessments)
                    let output = folder.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
                          exporter.supportedFileTypes.contains(.mp4) else {
                        throw ExportError("This video cannot be exported as MP4 by AVFoundation.")
                    }
                    exporter.outputURL = output
                    exporter.outputFileType = .mp4
                    exporter.timeRange = CMTimeRange(start: CMTime(seconds: clip.range.start, preferredTimescale: 60000),
                                                     duration: CMTime(seconds: clip.range.duration, preferredTimescale: 60000))
                    exporter.shouldOptimizeForNetworkUse = false
                    session = exporter
                    unfinishedFile = output
                    let progressTask = Task { [weak self] in
                        while !Task.isCancelled {
                            guard let self else { return }
                            self.progress = (Double(self.completedCount) + Double(exporter.progress)) / Double(self.totalCount)
                            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                        }
                    }
                    defer { progressTask.cancel() }
                    try checkCancellation()
                    if #available(macOS 15.0, *) {
                        try await exporter.export(to: output, as: .mp4)
                    } else {
                        try await exportOnMacOS14(exporter)
                    }
                    try checkCancellation()
                    unfinishedFile = nil
                    manifest.clips.append(.init(clip: clip, typePath: snapshot.typePath(for: clip),
                                                assessment: snapshot.assessment(for: clip)?.name, relativeFile: relative))
                    completedCount += 1
                    progress = Double(completedCount) / Double(totalCount)
                    try write(manifest, to: folder)
                }
                manifest.status = "completed"
                try write(manifest, to: folder)
                statusMessage = "Exported \(completedCount) \(completedCount == 1 ? "clip" : "clips")"
            } catch {
                if let unfinishedFile, FileManager.default.fileExists(atPath: unfinishedFile.path) {
                    do { try FileManager.default.removeItem(at: unfinishedFile) }
                    catch { errorMessage = "The unfinished file could not be removed: \(error.localizedDescription)" }
                }
                wasCancelled = cancellationRequested
                manifest.status = cancellationRequested ? "cancelled" : "failed"
                if !cancellationRequested { errorMessage = error.localizedDescription }
                manifest.error = errorMessage
                statusMessage = cancellationRequested ? "Cancelled · \(completedCount) finished clips retained" : "Export failed · \(completedCount) finished clips retained"
                if let outputFolder {
                    do { try write(manifest, to: outputFolder) }
                    catch { errorMessage = "\(errorMessage ?? statusMessage)\nThe export index could not be updated: \(error.localizedDescription)" }
                }
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        cancellationRequested = true
        statusMessage = "Cancelling…"
        session?.cancelExport()
    }

    private func checkCancellation() throws {
        if cancellationRequested { throw CancellationError() }
    }

    @available(macOS, introduced: 14.0, deprecated: 15.0)
    private func exportOnMacOS14(_ exporter: AVAssetExportSession) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { continuation.resume() }
        }
        guard exporter.status == .completed else {
            throw exporter.error ?? ExportError("The clip could not be exported.")
        }
    }

    private func createFolder(in parent: URL, named name: String) throws -> URL {
        let base = ClipExportSnapshot.safeComponent(name)
        for number in 1...10000 {
            let folder = parent.appendingPathComponent(number == 1 ? base : "\(base) (\(number))", isDirectory: true)
            // mkdir reserves a fresh directory atomically, including across app windows.
            if mkdir(folder.path, 0o755) == 0 { return folder }
            let code = errno
            if code == EEXIST { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        throw ExportError("Choose another session folder name.")
    }

    private func write(_ manifest: ClipExportManifest, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("clips.json"), options: .atomic)
    }

    private struct ExportError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
