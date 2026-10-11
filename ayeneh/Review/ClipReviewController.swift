import Combine
import Foundation

@MainActor
final class ClipReviewController: ObservableObject {
    let playback: PlaybackController
    let store: ClipStore
    let templates: ReviewTemplateStore
    @Published var draft: VideoClip? {
        didSet { scheduleAutosave(previous: oldValue) }
    }
    enum SaveStatus { case waitingForRange, saving, saved, failed }
    @Published private(set) var saveStatus = SaveStatus.waitingForRange
    @Published private(set) var focusRequest: ClipRange?
    @Published private(set) var focusRevision = 0
    private var autosaveTask: Task<Void, Never>?
    private var applyingSavedState = false
    @Published var showsPanel = true
    @Published var errorMessage: String?
    private var observation: AnyCancellable?
    private var lastTypeID: UUID?
    private var lastAssessmentID: UUID?

    init(playback: PlaybackController, store: ClipStore, templates: ReviewTemplateStore) {
        self.playback = playback
        self.store = store
        self.templates = templates
        observation = playback.$currentVideoID.removeDuplicates().sink { [weak self] _ in
            _ = self?.flushAutosave()
            self?.draft = nil
            self?.focusRequest = nil
            self?.errorMessage = nil
        }
    }

    var savedClips: [VideoClip] { store.clips(for: playback.currentVideoID) }
    var selectedTemplate: ReviewTemplate? { templates.template(draft?.templateID) }
    var isSaved: Bool { draft.map { draft in store.clips.contains { $0.id == draft.id } } ?? false }
    var validRange: Bool { draft?.range.isValid(for: playback.duration) == true }

    func request(_ action: @escaping () -> Void) {
        guard flushAutosave() else { return }
        action()
    }

    private func scheduleAutosave(previous: VideoClip?) {
        guard !applyingSavedState else { return }
        autosaveTask?.cancel()
        autosaveTask = nil
        guard let draft, validRange else { saveStatus = .waitingForRange; return }
        if store.clips.contains(draft) { saveStatus = .saved; return }
        saveStatus = .saving
        let onlyTextChanged = previous?.id == draft.id && previous?.range == draft.range
            && previous?.typeID == draft.typeID && previous?.assessmentID == draft.assessmentID
            && previous?.templateID == draft.templateID
        if onlyTextChanged {
            autosaveTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return }
                _ = self?.flushAutosave()
            }
        } else { _ = flushAutosave() }
    }

    @discardableResult
    func flushAutosave() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard let draft, validRange else { return true }
        guard draft.videoID == playback.currentVideoID else { return true }
        do {
            let saved = try store.save(draft, duration: playback.duration)
            // Preserve spaces while editing text; normalization belongs in the stored copy.
            applyingSavedState = true
            self.draft?.updatedAt = saved.updatedAt
            applyingSavedState = false
            lastTypeID = draft.typeID
            lastAssessmentID = draft.assessmentID
            saveStatus = .saved
            errorMessage = nil
            return true
        } catch {
            saveStatus = .failed
            errorMessage = "Clip changes could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    func focusClip(loopByDefault: Bool = false) {
        guard validRange else { return }
        focusRequest = draft?.range
        focusRevision += 1
        if loopByDefault { setLoop(true) }
    }
    func showOverview() { focusRequest = nil; focusRevision += 1; playback.setLoop(nil) }

    func newClip() {
        request { [weak self] in
            guard let self else { return }
            self.playback.setLoop(nil)
            self.playback.pause()
            let start = min(self.playback.currentTime, max(0, self.playback.duration - 0.02))
            self.makeDraft(range: ClipRange(start: start, end: min(self.playback.duration, start + 3)))
            self.focusClip(loopByDefault: true)
        }
    }

    private func makeDraft(range: ClipRange) {
        guard let videoID = playback.currentVideoID, playback.isReady, !playback.isLoading else { return }
        let templateID = playback.history?.videos.first { $0.id == videoID }?.reviewTemplateID
        let template = templates.template(templateID)
        draft = VideoClip(videoID: videoID, range: range, templateID: templateID,
                          typeID: template?.clipTypes.first { $0.id == lastTypeID && !$0.isArchived }?.id,
                          assessmentID: template?.assessments.first { $0.id == lastAssessmentID && !$0.isArchived }?.id)
        showsPanel = true
        errorMessage = nil
    }

    func markIn() {
        if draft == nil { makeDraft(range: ClipRange(start: playback.currentTime, end: playback.currentTime)) }
        guard var draft else { return }
        draft.range.start = isSaved ? min(playback.currentTime, draft.range.end - 0.02) : playback.currentTime
        if draft.range.end < draft.range.start { draft.range.end = draft.range.start }
        self.draft = draft
        updateLoop()
        showsPanel = true
    }

    func markOut() {
        let wasIncomplete = !validRange
        if draft == nil { makeDraft(range: ClipRange(start: max(0, playback.currentTime - 3), end: playback.currentTime)) }
        guard var draft else { return }
        draft.range.end = isSaved ? max(playback.currentTime, draft.range.start + 0.02) : playback.currentTime
        if draft.range.start > draft.range.end { draft.range.start = draft.range.end }
        self.draft = draft
        updateLoop()
        showsPanel = true
        focusClip(loopByDefault: wasIncomplete)
        if validRange { playback.pause() }
    }

    func setBoundary(start: Bool, time: Double) {
        guard var draft, time.isFinite else { return }
        playback.pause()
        let time = min(max(0, time), playback.duration)
        if start { draft.range.start = max(0, min(time, draft.range.end - 0.02)) }
        else { draft.range.end = min(playback.duration, max(time, draft.range.start + 0.02)) }
        self.draft = draft
        updateLoop()
        playback.seek(to: start ? draft.range.start : draft.range.end)
    }

    func drawRange(from start: Double, to end: Double) {
        request { [weak self] in
            guard let self else { return }
            self.playback.setLoop(nil)
            self.playback.pause()
            let duration = self.playback.duration
            let lower = min(max(0, min(start, end)), max(0, duration - 0.02))
            let upper = min(duration, max(lower + 0.02, max(start, end)))
            self.makeDraft(range: ClipRange(start: lower, end: upper))
            self.focusClip(loopByDefault: true)
            self.playback.seek(to: lower)
        }
    }

    func select(_ clip: VideoClip) {
        request { [weak self] in
            guard let self else { return }
            self.playback.pause()
            self.playback.setLoop(nil)
            var selected = self.store.clips.first { $0.id == clip.id } ?? clip
            if selected.templateID == nil {
                selected.templateID = self.playback.history?.videos.first { $0.id == selected.videoID }?.reviewTemplateID
            }
            self.draft = selected
            self.focusClip(loopByDefault: true)
            self.showsPanel = true
            self.errorMessage = nil
            self.playback.seek(to: selected.range.start)
        }
    }

    func setLoop(_ enabled: Bool) { playback.setLoop(enabled && validRange ? draft?.range : nil) }
    private func updateLoop() {
        if playback.loopRange != nil { playback.setLoop(validRange ? draft?.range : nil) }
    }

    func clear() {
        request { [weak self] in self?.draft = nil; self?.showOverview() }
    }

    func deselectIfOutside(at time: Double) {
        if let draft, !draft.range.contains(time) { clear() }
    }

    func removeSelected() {
        guard let draft else { return }
        if isSaved { store.remove(draft.id) }
        self.draft = nil
        showOverview()
    }

    func deleteSelection() {
        removeSelected()
    }

    func typeLabel(for clip: VideoClip) -> String {
        guard let template = templates.template(clip.templateID), let typeID = clip.typeID else { return "Uncategorized" }
        var names: [String] = []
        var current: UUID? = typeID
        var visited = Set<UUID>()
        while let id = current, visited.insert(id).inserted, let option = template.clipTypes.first(where: { $0.id == id }) {
            names.insert(option.name, at: 0)
            current = option.parentID
        }
        return names.isEmpty ? "Unavailable type" : names.joined(separator: " › ")
    }

    func color(for clip: VideoClip) -> ReviewColor {
        guard let template = templates.template(clip.templateID) else { return .blue }
        return typeColor(clip.typeID, in: template)
    }

    func typeColor(_ typeID: UUID?, in template: ReviewTemplate) -> ReviewColor {
        var current = typeID
        var visited = Set<UUID>()
        while let id = current, visited.insert(id).inserted, let type = template.clipTypes.first(where: { $0.id == id }) {
            if let color = type.color { return color }
            current = type.parentID
        }
        return template.color ?? .blue
    }

    func assessmentColor(for clip: VideoClip) -> ReviewColor? {
        templates.template(clip.templateID)?.assessments.first { $0.id == clip.assessmentID }.map { $0.color ?? .gray }
    }

    func hoverDetails(for clip: VideoClip) -> String {
        var lines = [clip.displayTitle,
                     "\(clipTimeLabel(clip.range.start)) – \(clipTimeLabel(clip.range.end)) · \(clipTimeLabel(clip.range.duration)) long"]
        if let template = templates.template(clip.templateID) { lines.append("Template: \(template.name)") }
        lines.append("Type: \(typeLabel(for: clip))")
        let assessment = templates.template(clip.templateID)?.assessments.first { $0.id == clip.assessmentID }
        lines.append("Assessment: \(assessment?.name ?? "Not assessed")")
        if !clip.note.isEmpty { lines.append("Note: \(clip.note)") }
        return lines.joined(separator: "\n")
    }
}
