import SwiftUI

struct VideoWorkspace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var playback: PlaybackController
    @StateObject private var review: ClipReviewController
    @StateObject private var exporter = ClipExportController()
    @State private var showsExport = false
    @State private var exportSnapshot: ClipExportSnapshot?
    @State private var editingTemplate: ReviewTemplate?
    let reviewTemplates: ReviewTemplateStore?

    init(history: WorkspaceHistoryStore? = nil, reviewTemplates: ReviewTemplateStore? = nil, clips: ClipStore? = nil) {
        let playback = PlaybackController(history: history)
        let templates = reviewTemplates ?? ReviewTemplateStore(defaults: UserDefaults(suiteName: "AyenehPreview")!)
        let clips = clips ?? ClipStore(profileID: templates.profileID, defaults: UserDefaults(suiteName: "AyenehPreview")!)
        _playback = StateObject(wrappedValue: playback)
        _review = StateObject(wrappedValue: ClipReviewController(playback: playback, store: clips, templates: templates))
        self.reviewTemplates = reviewTemplates
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if playback.filename != nil {
                    HStack(spacing: 0) {
                        ZStack {
                            Color.black
                            VideoViewport(player: playback.player)
                        }
                        if review.showsPanel {
                            Divider()
                            ClipReviewPanel(review: review, playback: playback, store: review.store, templates: review.templates)
                        }
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
                } else {
                    WorkspaceOverview(playback: playback, reviewTemplates: reviewTemplates, onEditTemplate: { editingTemplate = $0 })
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -8)))
                }
                if playback.isLoading {
                    ProgressView("Loading video…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if playback.filename != nil {
                PlaybackControls(playback: playback, review: review)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.18 : 0.32), value: playback.filename != nil)
        .frame(minWidth: 760, minHeight: 480)
        .navigationTitle(playback.filename ?? "Workspace")
        .toolbar {
            if playback.filename != nil || playback.isLoading {
                ToolbarItem(placement: .navigation) {
                    Button { review.request(playback.returnToWorkspace) } label: {
                        Label("Workspace", systemImage: "chevron.backward")
                    }
                    .help("Back to Workspace (⌘[)")
                }
            }
            if playback.filename != nil {
                ToolbarItem {
                    Button {
                        guard review.flushAutosave(), let videoID = playback.currentVideoID,
                              let sourceURL = playback.sourceURL else { return }
                        exportSnapshot = ClipExportSnapshot(sourceURL: sourceURL, videoID: videoID,
                                                            clips: review.savedClips, templates: review.templates.templates)
                        showsExport = true
                    } label: { Label("Export Clips", systemImage: "square.and.arrow.up") }
                    .disabled(exporter.isRunning || review.savedClips.isEmpty || !playback.isReady)
                    .help("Export clips from this video")
                }
                ToolbarItem {
                    Button { review.showsPanel.toggle() } label: { Label("Clips", systemImage: "sidebar.right") }
                        .help("Show or hide clip review")
                }
            }
            if exporter.isRunning || !exporter.statusMessage.isEmpty {
                ToolbarItem {
                    Button { exportSnapshot = nil; showsExport = true } label: {
                        if exporter.isRunning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("\(exporter.completedCount)/\(exporter.totalCount)").monospacedDigit()
                            }
                        } else {
                            Label(exporter.wasCancelled ? "Export Cancelled" : exporter.errorMessage == nil ? "Export" : "Export Failed",
                                  systemImage: exporter.errorMessage != nil ? "exclamationmark.triangle" : exporter.wasCancelled ? "stop.circle" : "checkmark.circle")
                        }
                    }.help(exporter.statusMessage)
                }
            }
            ToolbarItem {
                Button { review.request(playback.openVideo) } label: {
                    Label("Open Video", systemImage: "folder")
                }
                .help("Open a local video (⌘O)")
            }
        }
        .focusedSceneValue(\.playback, playback)
        .focusedSceneValue(\.clipReview, review)
        .sheet(item: $editingTemplate) { template in
            ReviewTemplateEditor(store: review.templates, template: template)
        }
        .sheet(isPresented: $showsExport) {
            ClipExportSheet(exporter: exporter, snapshot: exportSnapshot)
        }
        .alert("Video Workspace", isPresented: Binding(
            get: { playback.errorMessage != nil },
            set: { if !$0 { playback.errorMessage = nil } }
        )) {
            Button("OK") { playback.errorMessage = nil }
        } message: {
            Text(playback.errorMessage ?? "The video could not be opened.")
        }
        .alert("Video Unavailable", isPresented: Binding(
            get: { playback.unavailableVideo != nil },
            set: { if !$0 { playback.unavailableVideo = nil } }
        ), presenting: playback.unavailableVideo) { video in
            Button("Locate File…") { playback.locateVideo(video) }
            Button("Remove from History") { playback.removeFromHistory(video) }
            Button("Cancel", role: .cancel) { playback.unavailableVideo = nil }
        } message: { video in
            Text("\(video.filename) could not be reopened. Reconnect its drive or locate the file to restore this workspace.\n\n\(video.path)")
        }
        .task { playback.restoreLastVideo() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            exporter.cancel()
            review.flushAutosave()
            playback.saveWorkspacePosition()
        }
        .onDisappear { review.flushAutosave(); playback.shutdown() }
    }
}

#Preview { VideoWorkspace() }
