import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class PlaybackController: ObservableObject {
    let player = AVPlayer()
    let history: WorkspaceHistoryStore?
    var sourceURL: URL? { (player.currentItem?.asset as? AVURLAsset)?.url }
    static let speeds: [Float] = [0.25, 1, 2, 3, 4]
    static let shuttleSpeeds: [Float] = [1, 2, 3, 4]
    @Published private(set) var filename: String?
    @Published private(set) var duration = 0.0
    @Published private(set) var currentTime = 0.0 {
        didSet { checkpointPosition() }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published private(set) var canStepBackward = false
    @Published private(set) var canStepForward = false
    @Published private(set) var speed: Float = 1
    @Published private(set) var direction = 1
    @Published private(set) var usesSeekPlayback = false
    @Published private(set) var loopRange: ClipRange?
    @Published var errorMessage: String?
    @Published var unavailableVideo: RecentVideo?
    private var scopedURL: URL?
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var isScrubbing = false
    private var resumeAfterScrub = false
    private var pendingSeek: Double?
    private var seeking = false
    private var seekID = UUID()
    private var transportTask: Task<Void, Never>?
    @Published private(set) var currentVideoID: UUID?
    private var lastCheckpoint = 0.0
    private var didAttemptRestore = false
    private var restoringPosition = false

    init(history: WorkspaceHistoryStore? = nil) {
        self.history = history
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1 / 60, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isReady, !self.isScrubbing, !self.seeking, !self.usesSeekPlayback else { return }
                let time = self.player.currentTime()
                if time.seconds.isFinite {
                    self.currentTime = max(0, time.seconds)
                    self.enforceLoopBoundary()
                }
            }
        }
        playbackObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = self.usesSeekPlayback || self.player.timeControlStatus == .playing
            }
        }
    }

    func openVideo() {
        presentOpenPanel(replacing: nil)
    }

    func restoreLastVideo() {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              history?.restoresVideoOnLaunch == true,
              let video = history?.lastVideo else { return }
        openRecent(video)
    }

    func openRecent(_ video: RecentVideo) {
        saveWorkspacePosition()
        let latest = history?.videos.first { $0.id == video.id } ?? video
        do {
            guard let history else { return }
            let url = try history.resolve(latest)
            load(url, restoring: latest)
        } catch {
            unavailableVideo = latest
        }
    }

    func locateVideo(_ video: RecentVideo) {
        unavailableVideo = nil
        presentOpenPanel(replacing: video)
    }

    func removeFromHistory(_ video: RecentVideo) {
        history?.remove(video.id)
        if currentVideoID == video.id { currentVideoID = nil }
        if unavailableVideo?.id == video.id { unavailableVideo = nil }
    }

    func returnToWorkspace() {
        didAttemptRestore = true
        shutdown()
        history?.showWorkspaceOnLaunch()
        unavailableVideo = nil
        errorMessage = nil
    }

    private func presentOpenPanel(replacing video: RecentVideo?) {
        let panel = NSOpenPanel()
        panel.title = video.map { "Locate \($0.filename)" } ?? "Open Video"
        panel.allowedContentTypes = [.movie]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard response == .OK, let url = panel.url else { return }
                self?.load(url, restoring: video)
            }
        }
    }

    func load(_ url: URL, restoring video: RecentVideo? = nil) {
        saveWorkspacePosition()
        let entry = video.flatMap { selected in history?.videos.first { $0.id == selected.id } ?? selected }
            ?? history?.entry(for: url)
        let position = entry?.position ?? 0
        loadTask?.cancel()
        let id = UUID()
        loadID = id
        isLoading = true
        errorMessage = nil
        unavailableVideo = nil
        loadTask = Task { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            var transferred = false
            defer { if scoped && !transferred { url.stopAccessingSecurityScopedResource() } }
            do {
                let asset = AVURLAsset(url: url)
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                try Task.checkCancellation()
                guard let self, self.loadID == id else { return }
                guard playable, !tracks.isEmpty, duration.isFinite, duration > 0 else {
                    throw NSError(domain: "Ayeneh", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a playable video with a finite duration."])
                }
                self.resetItem()
                self.scopedURL = scoped ? url : nil
                transferred = true
                self.filename = url.lastPathComponent
                self.duration = duration
                let initialPosition = min(max(0, position.isFinite ? position : 0), duration)
                let item = AVPlayerItem(asset: asset)
                self.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.player.currentItem === item else { return }
                        switch item.status {
                        case .readyToPlay:
                            guard !self.isReady else { return }
                            self.isReady = true
                            self.canStepBackward = item.canStepBackward
                            self.canStepForward = item.canStepForward
                            do {
                                self.currentVideoID = try self.history?.remember(url, replacing: entry, position: initialPosition)
                            } catch {
                                self.errorMessage = "The video opened, but its workspace could not be saved: \(error.localizedDescription)"
                            }
                            self.lastCheckpoint = ProcessInfo.processInfo.systemUptime
                            if initialPosition > 0 {
                                self.restoringPosition = true
                                self.seek(to: initialPosition)
                            } else {
                                self.isLoading = false
                            }
                        case .failed:
                            self.pause()
                            self.isLoading = false
                            self.isReady = false
                            if let entry { self.unavailableVideo = entry }
                            else { self.errorMessage = item.error?.localizedDescription ?? "This video could not be played." }
                        default: break
                        }
                    }
                }
                self.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.player.currentItem === item,
                              !self.seeking, !self.isScrubbing, !self.usesSeekPlayback else { return }
                        let endTime = self.direction < 0 ? 0 : self.duration
                        if self.loopRange != nil {
                            self.restartLoop()
                            return
                        }
                        self.pause()
                        self.currentTime = endTime
                    }
                }
                self.player.replaceCurrentItem(with: item)
            } catch {
                guard let self, self.loadID == id, !Task.isCancelled else { return }
                self.isLoading = false
                if let entry { self.unavailableVideo = entry }
                else { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func togglePlayback() {
        guard isReady, !isLoading, !isScrubbing else { return }
        if isPlaying || player.rate != 0 || resumeAfterScrub { pause() }
        else {
            resetPlaybackRate()
            startPlayback()
        }
    }

    func shuttle(_ requestedDirection: Int) {
        guard isReady, !isLoading, !isScrubbing else { return }
        let requestedDirection = requestedDirection < 0 ? -1 : 1
        // The opposite button cancels fast playback back to normal forward 1×.
        // Otherwise advance from the actual selected rate, avoiding an extra 1× click.
        let returnsToNormal = speed > 1 && direction != requestedDirection
        let index = Self.shuttleSpeeds.firstIndex(of: speed) ?? 0
        let nextSpeed = returnsToNormal ? 1 : Self.shuttleSpeeds[(index + 1) % Self.shuttleSpeeds.count]
        stopTransport()
        cancelSeeks()
        resumeAfterScrub = false
        direction = returnsToNormal ? 1 : requestedDirection
        speed = nextSpeed
        player.defaultRate = speed
        startPlayback()
    }

    private func startPlayback() {
        if let loopRange, !loopRange.contains(currentTime) || (direction > 0 ? currentTime >= loopRange.end : currentTime <= loopRange.start) {
            restartLoop()
            return
        }
        if direction > 0 && currentTime >= duration || direction < 0 && currentTime <= 0 {
            resumeAfterScrub = true
            seek(to: direction > 0 ? 0 : duration)
        } else { startRunningPlayback() }
    }

    private func startRunningPlayback() {
        guard isReady, !isScrubbing, let item = player.currentItem else { return }
        stopTransport()
        let supported: Bool
        if direction < 0 {
            supported = speed < 1 ? item.canPlaySlowReverse : speed == 1 ? item.canPlayReverse : item.canPlayFastReverse
        } else {
            supported = speed < 1 ? item.canPlaySlowForward : speed <= 2 || item.canPlayFastForward
        }
        isPlaying = true
        if supported {
            player.playImmediately(atRate: speed * Float(direction))
        } else {
            // Silent shuttle preview for codecs without native reverse/fast playback.
            usesSeekPlayback = true
            let origin = currentTime
            let start = ProcessInfo.processInfo.systemUptime
            let rate = Double(speed) * Double(direction)
            transportTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(33)) }
                    catch { return }
                    guard let self, self.usesSeekPlayback, self.isReady else { return }
                    let target = origin + (ProcessInfo.processInfo.systemUptime - start) * rate
                    if let range = self.loopRange, target <= range.start || target >= range.end {
                        self.restartLoop()
                        return
                    }
                    self.seek(to: target)
                    if target <= 0 || target >= self.duration {
                        self.pause()
                        return
                    }
                }
            }
        }
    }

    private func stopTransport() {
        transportTask?.cancel()
        transportTask = nil
        usesSeekPlayback = false
        player.pause()
        isPlaying = false
    }

    func setSpeed(_ value: Float) {
        guard Self.speeds.contains(value) else { return }
        let wasPlaying = isPlaying || player.rate != 0 || resumeAfterScrub
        stopTransport()
        cancelSeeks()
        resumeAfterScrub = false
        speed = value
        player.defaultRate = value
        if wasPlaying { startPlayback() }
    }

    func pause() {
        stopTransport()
        resumeAfterScrub = false
        resetPlaybackRate()
        saveWorkspacePosition()
    }

    private func resetPlaybackRate() {
        direction = 1
        speed = 1
        player.defaultRate = 1
    }

    func stepFrame(_ direction: Int) {
        guard isReady, !isLoading, !isScrubbing,
              direction > 0 ? canStepForward : canStepBackward else { return }
        pause()
        self.direction = 1
        cancelSeeks()
        player.currentItem?.step(byCount: direction > 0 ? 1 : -1)
    }

    func beginScrubbing() {
        guard isReady else { return }
        resumeAfterScrub = isPlaying || player.rate != 0 || resumeAfterScrub
        stopTransport()
        isScrubbing = true
    }

    func endScrubbing(at time: Double) {
        isScrubbing = false
        seek(to: time)
    }

    func seek(to time: Double) {
        guard isReady, time.isFinite else { return }
        let target = loopRange?.clamped(time) ?? min(max(0, time), duration)
        currentTime = target
        pendingSeek = target
        performPendingSeek()
    }

    func seekFromTimeline(to time: Double) {
        if let loopRange, !loopRange.contains(time) { setLoop(nil) }
        seek(to: time)
    }

    func setLoop(_ range: ClipRange?) {
        loopRange = range.flatMap { $0.isValid(for: duration) ? $0 : nil }
        player.currentItem?.forwardPlaybackEndTime = loopRange.map { CMTime(seconds: $0.end, preferredTimescale: 60000) } ?? .invalid
        player.currentItem?.reversePlaybackEndTime = loopRange.map { CMTime(seconds: $0.start, preferredTimescale: 60000) } ?? .zero
        if let loopRange, !loopRange.contains(currentTime) {
            let wasPlaying = isPlaying || player.rate != 0
            stopTransport()
            resumeAfterScrub = wasPlaying
            seek(to: loopRange.start)
        }
    }

    private func enforceLoopBoundary() {
        guard let range = loopRange else { return }
        if isPlaying, direction > 0 ? currentTime >= range.end : currentTime <= range.start {
            restartLoop()
        } else if !isPlaying, currentTime < range.start || currentTime > range.end {
            seek(to: range.clamped(currentTime))
        }
    }

    private func restartLoop() {
        guard let range = loopRange else { return }
        stopTransport()
        resumeAfterScrub = true
        seek(to: direction > 0 ? range.start : range.end)
    }

    private func performPendingSeek() {
        guard !seeking, let target = pendingSeek else { return }
        pendingSeek = nil
        seeking = true
        let id = seekID
        player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.seekID == id else { return }
                self.seeking = false
                if self.pendingSeek != nil { self.performPendingSeek() }
                else if !self.isScrubbing {
                    let actual = self.player.currentTime().seconds
                    if actual.isFinite, !self.usesSeekPlayback { self.currentTime = actual }
                    if self.restoringPosition {
                        self.restoringPosition = false
                        self.isLoading = false
                        self.saveWorkspacePosition()
                    }
                    if finished, self.resumeAfterScrub {
                        self.resumeAfterScrub = false
                        self.startRunningPlayback()
                    }
                }
            }
        }
    }

    private func cancelSeeks() {
        seekID = UUID()
        pendingSeek = nil
        seeking = false
        player.currentItem?.cancelPendingSeeks()
    }

    private func resetItem() {
        pause()
        setLoop(nil)
        currentVideoID = nil
        restoringPosition = false
        direction = 1
        cancelSeeks()
        isScrubbing = false
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        isReady = false
        canStepBackward = false
        canStepForward = false
        currentTime = 0
        duration = 0
    }

    private func checkpointPosition() {
        guard isReady, !restoringPosition,
              ProcessInfo.processInfo.systemUptime - lastCheckpoint >= 5 else { return }
        saveWorkspacePosition()
    }

    func saveWorkspacePosition() {
        guard isReady, !restoringPosition, let currentVideoID else { return }
        history?.savePosition(currentTime, for: currentVideoID)
        lastCheckpoint = ProcessInfo.processInfo.systemUptime
    }

    func shutdown() {
        loadTask?.cancel()
        transportTask?.cancel()
        loadID = UUID()
        resetItem()
        filename = nil
        isLoading = false
    }

    deinit {
        loadTask?.cancel()
        transportTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        scopedURL?.stopAccessingSecurityScopedResource()
    }
}
