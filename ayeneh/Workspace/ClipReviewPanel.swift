import SwiftUI

struct ClipReviewPanel: View {
    @ObservedObject var review: ClipReviewController
    @ObservedObject var playback: PlaybackController
    @ObservedObject var store: ClipStore
    @ObservedObject var templates: ReviewTemplateStore
    @FocusState private var editingText: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clips").font(.headline)
                Spacer()
                Button { review.newClip() } label: { Image(systemName: "plus") }
                    .help("New clip at playhead")
                Button { review.showsPanel = false } label: { Image(systemName: "sidebar.right") }
                    .help("Hide clip panel")
            }.buttonStyle(.borderless).padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if review.draft != nil {
                        editor
                    } else {
                        Text("Mark a moment").font(.headline)
                        Text("Press I for the start and O for the end, or drag across the selection lane below the timeline.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("New Clip", systemImage: "plus") { review.newClip() }
                    }
                    Divider()
                    Text("Saved clips · \(review.savedClips.count)").font(.subheadline.weight(.semibold))
                    if review.savedClips.isEmpty {
                        Text("Saved ranges appear here and on the timeline.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(review.savedClips) { clip in
                        Button { review.select(clip) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Circle().fill(review.color(for: clip).swatch).frame(width: 7, height: 7)
                                    Text(clip.displayTitle).font(.callout.weight(.medium)).lineLimit(1)
                                }
                                Text("\(clipTimeLabel(clip.range.start)) – \(clipTimeLabel(clip.range.end))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(review.typeLabel(for: clip)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if let assessment = templates.template(clip.templateID)?.assessments.first(where: { $0.id == clip.assessmentID }) {
                                    HStack(spacing: 5) {
                                        Circle().fill((assessment.color ?? .gray).swatch).frame(width: 6, height: 6)
                                        Text(assessment.name).font(.caption.weight(.medium))
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(review.color(for: clip).swatch.opacity(review.draft?.id == clip.id ? 0.15 : 0.06),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(review.hoverDetails(for: clip))
                    }
                }.padding(16)
            }
        }
        .frame(width: 290)
        .background(.background)
        .focusedSceneValue(\.isEditingClipText, editingText)
        .disabled(!playback.isReady || playback.isLoading)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(review.isSaved ? "Selected clip" : "New clip").font(.headline)
                Spacer()
                Text(saveStatus).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Clip name (optional)", text: field(\.title))
                .focused($editingText)
                .textFieldStyle(.roundedBorder)
            boundary(start: true)
            boundary(start: false)
            if let range = review.draft?.range {
                Text("Duration \(clipTimeLabel(range.duration))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Toggle("Loop selected range", isOn: Binding(get: { playback.loopRange != nil }, set: review.setLoop))
                .toggleStyle(.switch).controlSize(.small).disabled(!review.validRange)
            if let template = review.selectedTemplate {
                Label {
                    Text(template.name + (template.isArchived ? " (archived)" : ""))
                } icon: { Image(nsImage: (template.color ?? .blue).menuImage) }
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Circle().fill(review.draft.map { review.color(for: $0).swatch } ?? .gray)
                        .frame(width: 10, height: 10).accessibilityHidden(true)
                    Picker("Clip type", selection: option(\.typeID)) {
                        Text("Uncategorized").tag(Optional<UUID>.none)
                        ForEach(ReviewTypeHierarchy.rows(template.clipTypes)) { row in
                            Label {
                                Text(row.path)
                            } icon: { Image(nsImage: review.typeColor(row.id, in: template).menuImage) }
                            .tag(Optional(row.id))
                        }
                        if let id = review.draft?.typeID, !ReviewTypeHierarchy.rows(template.clipTypes).contains(where: { $0.id == id }) {
                            Text(review.draft.map(review.typeLabel) ?? "Unavailable type").tag(Optional(id))
                        }
                    }
                }
                HStack(spacing: 6) {
                    Circle().fill((review.draft.flatMap { review.assessmentColor(for: $0) } ?? .gray).swatch)
                        .frame(width: 10, height: 10).accessibilityHidden(true)
                    Picker("Assessment", selection: option(\.assessmentID)) {
                        Text("Not assessed").tag(Optional<UUID>.none)
                        ForEach(template.assessments.filter { !$0.isArchived }) { assessment in
                            Label {
                                Text(assessment.name)
                            } icon: { Image(nsImage: (assessment.color ?? .gray).menuImage) }
                            .tag(Optional(assessment.id))
                        }
                        if let id = review.draft?.assessmentID, !template.assessments.contains(where: { $0.id == id && !$0.isArchived }) {
                            Text(template.assessments.first { $0.id == id }.map { "\($0.name) (archived)" } ?? "Unavailable assessment")
                                .tag(Optional(id))
                        }
                    }
                }
            } else {
                Text("This clip is uncategorized. Assign a review template to the video in Workspace to categorize new clips.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Note (optional)", text: field(\.note), axis: .vertical)
                .focused($editingText)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            if let message = review.errorMessage { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Changes save automatically.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: review.deleteSelection) { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(review.isSaved ? "Delete selected clip" : "Clear unsaved clip")
                .accessibilityLabel(review.isSaved ? "Delete selected clip" : "Clear unsaved clip")
            }
        }
    }

    private var saveStatus: String {
        switch review.saveStatus {
        case .waitingForRange: "Mark an end"
        case .saving: "Saving…"
        case .saved: "Saved"
        case .failed: "Not saved"
        }
    }

    private func boundary(start: Bool) -> some View {
        let time = start ? review.draft?.range.start ?? 0 : review.draft?.range.end ?? 0
        return HStack {
            Text(start ? "In" : "Out").foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            Button(clipTimeLabel(time)) { playback.pause(); playback.seek(to: time) }
                .font(.callout.monospacedDigit()).buttonStyle(.borderless).help("Seek to this boundary")
            Spacer()
            Button("Set") { start ? review.markIn() : review.markOut() }
                .controlSize(.small).help("Set to playhead (\(start ? "I" : "O"))")
        }
    }

    private func field(_ key: WritableKeyPath<VideoClip, String>) -> Binding<String> {
        Binding(get: { review.draft?[keyPath: key] ?? "" }, set: { review.draft?[keyPath: key] = $0 })
    }

    private func option(_ key: WritableKeyPath<VideoClip, UUID?>) -> Binding<UUID?> {
        Binding(get: { review.draft?[keyPath: key] }, set: { review.draft?[keyPath: key] = $0 })
    }
}
