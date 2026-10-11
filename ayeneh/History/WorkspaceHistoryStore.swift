import Combine
import Foundation
import AppKit

struct RecentVideo: Codable, Identifiable {
    let id: UUID
    var bookmark: Data
    var filename: String
    var path: String
    var lastOpened: Date
    var position: Double
    var details: VideoDetails?
    var reviewTemplateID: UUID?
}

@MainActor
final class WorkspaceHistoryStore: ObservableObject {
    @Published private(set) var videos: [RecentVideo] = []
    private(set) var lastVideoID: UUID?
    private(set) var restoresVideoOnLaunch = true
    private let cacheDirectory: URL
    private let defaults: UserDefaults
    private let key = "videoWorkspaceHistory.v1"

    private struct SavedHistory: Codable {
        var videos: [RecentVideo]
        var lastVideoID: UUID?
        var restoresVideoOnLaunch: Bool?
    }

    init(defaults: UserDefaults = .standard, cacheDirectory: URL? = nil) {
        self.defaults = defaults
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ayeneh/VideoThumbnails", isDirectory: true)
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(SavedHistory.self, from: data) {
            videos = saved.videos.sorted { $0.lastOpened > $1.lastOpened }
            lastVideoID = saved.lastVideoID
            restoresVideoOnLaunch = saved.restoresVideoOnLaunch ?? true
        }
    }

    var lastVideo: RecentVideo? { videos.first { $0.id == lastVideoID } }

    func resolve(_ video: RecentVideo) throws -> URL {
        var stale = false
        // Don't display system UI or attempt to mount disconnected drives during restoration.
        return try URL(resolvingBookmarkData: video.bookmark,
                       options: [.withSecurityScope, .withoutUI, .withoutMounting],
                       relativeTo: nil, bookmarkDataIsStale: &stale)
        // Successful loads create a fresh bookmark, including when the old one was stale.
    }

    func entry(for url: URL) -> RecentVideo? {
        let path = url.standardizedFileURL.path
        return videos.first {
            $0.path == path || (try? resolve($0).standardizedFileURL.path) == path
        }
    }

    /// Call while the selected file's security scope is active.
    @discardableResult
    func remember(_ url: URL, replacing existing: RecentVideo?, position: Double) throws -> UUID {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                           includingResourceValuesForKeys: nil, relativeTo: nil)
        let matching = entry(for: url)
        let id = existing?.id ?? matching?.id ?? UUID()
        let previous = videos.first { $0.id == id }
        let samePath = previous?.path == url.standardizedFileURL.path
        if !samePath { try? FileManager.default.removeItem(at: thumbnailURL(id)) }
        let video = RecentVideo(id: id, bookmark: bookmark, filename: url.lastPathComponent,
                                path: url.standardizedFileURL.path, lastOpened: Date(),
                                position: position.isFinite ? max(0, position) : 0,
                                details: samePath ? previous?.details : nil,
                                reviewTemplateID: previous?.reviewTemplateID)
        videos.removeAll { $0.id == id || $0.id == matching?.id }
        videos.insert(video, at: 0)
        lastVideoID = id
        restoresVideoOnLaunch = true
        persist()
        return id
    }

    func savePosition(_ position: Double, for id: UUID) {
        guard position.isFinite, let index = videos.firstIndex(where: { $0.id == id }) else { return }
        // Position checkpoints don't reorder history or change the last-opened workspace.
        videos[index].position = max(0, position)
        persist()
    }

    func assignReviewTemplate(_ templateID: UUID?, to videoID: UUID) {
        guard let index = videos.firstIndex(where: { $0.id == videoID }) else { return }
        videos[index].reviewTemplateID = templateID
        persist()
    }

    func remove(_ id: UUID) {
        videos.removeAll { $0.id == id }
        if lastVideoID == id { lastVideoID = videos.first?.id }
        if lastVideoID == nil { restoresVideoOnLaunch = false }
        try? FileManager.default.removeItem(at: thumbnailURL(id))
        persist()
    }

    func showWorkspaceOnLaunch() {
        restoresVideoOnLaunch = false
        persist()
    }

    func preview(for video: RecentVideo) async -> VideoPreview {
        let cached = NSImage(contentsOf: thumbnailURL(video.id))
        do {
            let url = try resolve(video)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if let details = video.details, details.fileSize == attributes.fileSize,
               details.fileModified == attributes.contentModificationDate, let cached {
                return VideoPreview(image: cached, unavailable: false)
            }
            let details = try await VideoInspector.details(for: url)
            let imageData = try? await VideoInspector.thumbnail(for: url, duration: details.duration)
            try Task.checkCancellation()
            guard let index = videos.firstIndex(where: { $0.id == video.id && $0.bookmark == video.bookmark }) else {
                return VideoPreview(image: nil, unavailable: false)
            }
            videos[index].details = details
            persist()
            if let imageData {
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try? imageData.write(to: thumbnailURL(video.id), options: .atomic)
                return VideoPreview(image: NSImage(data: imageData), unavailable: false)
            }
            return VideoPreview(image: nil, unavailable: false)
        } catch {
            return VideoPreview(image: cached, unavailable: !Task.isCancelled)
        }
    }

    private func thumbnailURL(_ id: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(id.uuidString).jpg")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(SavedHistory(videos: videos, lastVideoID: lastVideoID,
                                                          restoresVideoOnLaunch: restoresVideoOnLaunch)) {
            defaults.set(data, forKey: key)
        }
    }
}
