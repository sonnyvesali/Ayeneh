import Combine
import Foundation

struct ClipRange: Codable, Equatable {
    var start: Double
    var end: Double
    var duration: Double { end - start }
    func contains(_ time: Double) -> Bool { time >= start && time <= end }
    func clamped(_ time: Double) -> Double { min(max(start, time), end) }
    func isValid(for duration: Double) -> Bool {
        start.isFinite && end.isFinite && duration.isFinite && start >= 0 && end <= duration && end - start >= 0.02 - 1e-9
    }
}

struct VideoClip: Codable, Identifiable, Equatable {
    var id = UUID()
    var videoID: UUID
    var range: ClipRange
    var title = ""
    var templateID: UUID?
    var typeID: UUID?
    var assessmentID: UUID?
    var note = ""
    var updatedAt = Date()

    var displayTitle: String { title.isEmpty ? "Clip at \(clipTimeLabel(range.start))" : title }
}

@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var clips: [VideoClip]
    private let defaults: UserDefaults
    private let key: String

    init(profileID: UUID, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "videoClips.v1.\(profileID.uuidString)"
        clips = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([VideoClip].self, from: $0) } ?? []
    }

    func clips(for videoID: UUID?) -> [VideoClip] {
        clips.filter { $0.videoID == videoID }.sorted {
            $0.range.start == $1.range.start ? $0.id.uuidString < $1.id.uuidString : $0.range.start < $1.range.start
        }
    }

    func save(_ draft: VideoClip, duration: Double) throws -> VideoClip {
        guard draft.range.isValid(for: duration) else {
            throw ReviewTemplateStore.ValidationError(message: "Choose a range of at least 0.02 seconds within this video.")
        }
        var saved = draft
        saved.title = saved.title.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.note = saved.note.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.updatedAt = Date()
        var updated = clips
        if let index = updated.firstIndex(where: { $0.id == saved.id }) { updated[index] = saved }
        else { updated.append(saved) }
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: key)
        clips = updated
        return saved
    }

    func remove(_ id: UUID) {
        clips.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(clips) { defaults.set(data, forKey: key) }
    }
}

func clipTimeLabel(_ time: Double) -> String {
    let milliseconds = Int((max(0, time.isFinite ? time : 0) * 1000).rounded())
    return String(format: "%d:%02d.%03d", milliseconds / 60000, (milliseconds / 1000) % 60, milliseconds % 1000)
}
