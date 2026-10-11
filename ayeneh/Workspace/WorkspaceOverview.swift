import SwiftUI

struct WorkspaceOverview: View {
    @ObservedObject var playback: PlaybackController
    let reviewTemplates: ReviewTemplateStore?
    let onEditTemplate: (ReviewTemplate) -> Void
    @SceneStorage("workspace.selectedSection") private var selectedSection = WorkspaceSection.videos.rawValue

    private enum WorkspaceSection: String, CaseIterable {
        case videos = "Videos"
        case templates = "Review Templates"

        var symbol: String { self == .videos ? "video" : "rectangle.stack" }
        var description: String {
            self == .videos
                ? "Open a local video or pick up where you left off."
                : "Create reusable clip types and assessments for your videos."
        }
    }

    private var section: WorkspaceSection {
        let saved = WorkspaceSection(rawValue: selectedSection) ?? .videos
        return reviewTemplates == nil ? .videos : saved
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<WorkspaceSection?>(
                get: { section },
                set: { if let selection = $0 { selectedSection = selection.rawValue } }
            )) {
                Section("Workspace") {
                    ForEach(WorkspaceSection.allCases.filter { reviewTemplates != nil || $0 == .videos }, id: \.self) { destination in
                        Label(destination.rawValue, systemImage: destination.symbol)
                            .tag(destination)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .accessibilityLabel("Workspace navigation")
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.rawValue).font(.largeTitle.bold())
                    Text(section.description).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)

                if section == .templates, let reviewTemplates {
                    ReviewTemplateLibrary(store: reviewTemplates, onEdit: onEditTemplate)
                } else if let history = playback.history {
                    WorkspaceVideoList(playback: playback, history: history, reviewTemplates: reviewTemplates)
                } else {
                    EmptyWorkspace(playback: playback)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct WorkspaceVideoList: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject var history: WorkspaceHistoryStore
    let reviewTemplates: ReviewTemplateStore?

    var body: some View {
        if history.videos.isEmpty {
            EmptyWorkspace(playback: playback)
        } else {
            GeometryReader { geometry in
                let compact = geometry.size.width < 680
                let templateWidth: CGFloat = compact ? 140 : 180
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Video").frame(maxWidth: .infinity, alignment: .leading)
                        if reviewTemplates != nil {
                            Text("Review template").frame(width: templateWidth, alignment: .leading)
                        }
                        if !compact { Text("Last opened").frame(width: 110, alignment: .leading) }
                        Color.clear.frame(width: 52, height: 1)
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    Divider()
                    List(history.videos) { video in
                        WorkspaceVideoRow(video: video, playback: playback, history: history,
                                          reviewTemplates: reviewTemplates, compact: compact, templateWidth: templateWidth)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                    .listStyle(.plain)
                }
            }
        }
    }
}

private struct WorkspaceVideoRow: View {
    let video: RecentVideo
    @ObservedObject var playback: PlaybackController
    @ObservedObject var history: WorkspaceHistoryStore
    let reviewTemplates: ReviewTemplateStore?
    let compact: Bool
    let templateWidth: CGFloat
    @State private var preview: VideoPreview?
    @State private var showsInfo = false

    var body: some View {
        HStack(spacing: 12) {
            Button { playback.openRecent(video) } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Color.black
                        if let image = preview?.image {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else if preview == nil {
                            ProgressView().controlSize(.mini).colorScheme(.dark)
                        } else {
                            Image(systemName: "video.slash").foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .frame(width: compact ? 64 : 80, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(video.filename).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(video.filename)")
            if let reviewTemplates {
                WorkspaceTemplatePicker(video: video, history: history, templates: reviewTemplates)
                    .pickerStyle(.menu).labelsHidden().controlSize(.small)
                    .frame(width: templateWidth)
            }
            if !compact {
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.lastOpened, format: .dateTime.month(.abbreviated).day())
                    Text(video.lastOpened, format: .dateTime.hour().minute()).foregroundStyle(.secondary)
                }
                .font(.caption).frame(width: 110, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button { showsInfo.toggle() } label: { Image(systemName: "info.circle").frame(width: 22, height: 24) }
                    .buttonStyle(.borderless).help("Video information")
                    .accessibilityLabel("Information for \(video.filename)")
                    .popover(isPresented: $showsInfo) {
                        WorkspaceVideoInfo(video: video, unavailable: preview?.unavailable == true)
                    }
                Menu {
                    videoOptions
                } label: { Image(systemName: "ellipsis").frame(width: 22, height: 24) }
                .menuIndicator(.hidden).fixedSize().help("Video options")
                .accessibilityLabel("Options for \(video.filename)")
            }
            .frame(width: 52)
        }
        .frame(height: 72)
        .contextMenu {
            Button("Open") { playback.openRecent(video) }
            Button("Get Info") { showsInfo = true }
            videoOptions
            if let reviewTemplates {
                WorkspaceTemplateMenu(video: video, history: history, templates: reviewTemplates)
            }
        }
        .task(id: video.bookmark) { preview = await history.preview(for: video) }
    }

    private var summary: String {
        if preview?.unavailable == true { return "File unavailable · Locate File to reconnect" }
        var values: [String] = []
        if let details = video.details {
            values.append(timeLabel(details.duration))
            if let captured = details.capturedAt {
                values.append("Recorded \(captured.formatted(date: .abbreviated, time: .omitted))")
            }
        }
        if video.position > 0 { values.append("Resume \(timeLabel(video.position))") }
        return values.isEmpty ? "Reading video information…" : values.joined(separator: " · ")
    }

    private var videoOptions: some View {
        Group {
            Button("Locate File…") { playback.locateVideo(video) }
            Button("Remove from History") { playback.removeFromHistory(video) }
        }
    }
}

private struct WorkspaceTemplateMenu: View {
    let video: RecentVideo
    @ObservedObject var history: WorkspaceHistoryStore
    @ObservedObject var templates: ReviewTemplateStore

    var body: some View {
        Menu("Review Template") {
            WorkspaceTemplatePicker(video: video, history: history, templates: templates, showsSelectedColor: false)
                .pickerStyle(.inline)
        }
    }
}

private struct WorkspaceTemplatePicker: View {
    let video: RecentVideo
    @ObservedObject var history: WorkspaceHistoryStore
    @ObservedObject var templates: ReviewTemplateStore
    var showsSelectedColor = true

    private var selectedID: UUID? { history.videos.first { $0.id == video.id }?.reviewTemplateID }

    var body: some View {
        if showsSelectedColor {
            HStack(spacing: 6) {
                Circle().fill((templates.template(selectedID)?.color ?? (selectedID == nil ? .gray : .blue)).swatch)
                    .frame(width: 10, height: 10).accessibilityHidden(true)
                picker
            }
        } else { picker }
    }

    private var picker: some View {
        Picker("Review template", selection: Binding(
            get: { selectedID },
            set: { history.assignReviewTemplate($0, to: video.id) }
        )) {
            Text("No template").tag(Optional<UUID>.none)
            ForEach(templates.activeTemplates) { template in
                Label {
                    Text(template.name)
                } icon: { Image(nsImage: (template.color ?? .blue).menuImage) }
                .tag(Optional(template.id))
            }
            if let id = selectedID, !templates.activeTemplates.contains(where: { $0.id == id }) {
                Text(templates.template(id).map { "\($0.name) (archived)" } ?? "Unavailable template")
                    .tag(Optional(id))
            }
        }
        .accessibilityLabel("Review template for \(video.filename)")
    }
}

private struct EmptyWorkspace: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        ContentUnavailableView {
            Label("No Recent Videos", systemImage: "video")
        } description: {
            Text("Your videos stay in their original locations.")
        } actions: {
            Button("Open Video…", action: playback.openVideo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
