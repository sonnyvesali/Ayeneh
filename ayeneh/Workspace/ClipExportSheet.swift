import AppKit
import SwiftUI

struct ClipExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var exporter: ClipExportController
    let snapshot: ClipExportSnapshot?
    @State private var selected = Set<UUID>()
    @State private var sessionName = ""
    @State private var destination: URL?
    @State private var organized = true
    @State private var groupAssessments = true
    @State private var showResult: Bool

    init(exporter: ClipExportController, snapshot: ClipExportSnapshot?) {
        self.exporter = exporter
        self.snapshot = snapshot
        _showResult = State(initialValue: exporter.isRunning || snapshot == nil)
        _selected = State(initialValue: Set(snapshot?.clips.map(\.id) ?? []))
        _sessionName = State(initialValue: snapshot?.sourceURL.deletingPathExtension().lastPathComponent ?? "Clips")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Clips").font(.title2.weight(.semibold))
            if showResult {
                Text(exporter.statusMessage).font(.headline)
                if exporter.isRunning {
                    ProgressView(value: exporter.progress)
                    Text(exporter.currentTitle).font(.caption).foregroundStyle(.secondary)
                    Text("You can close this window and keep reviewing.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = exporter.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let folder = exporter.outputFolder { Text(folder.path).font(.caption).textSelection(.enabled) }
                HStack {
                    if let folder = exporter.outputFolder {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                    Spacer()
                    if exporter.isRunning { Button("Cancel Export", role: .destructive) { exporter.cancel() } }
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            } else if let snapshot {
                HStack {
                    Text("\(selected.count) of \(snapshot.clips.count) clips selected").foregroundStyle(.secondary)
                    Spacer()
                    Button(selected.count == snapshot.clips.count ? "Deselect All" : "Select All") {
                        selected = selected.count == snapshot.clips.count ? [] : Set(snapshot.clips.map(\.id))
                    }.buttonStyle(.borderless)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(snapshot.clips) { clip in
                            Toggle(isOn: Binding(get: { selected.contains(clip.id) }, set: { enabled in
                                if enabled { selected.insert(clip.id) } else { selected.remove(clip.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(clip.displayTitle)
                                    Text("\(clipTimeLabel(clip.range.start)) – \(clipTimeLabel(clip.range.end)) · \(snapshot.typePath(for: clip).joined(separator: " › ")) · \(snapshot.assessment(for: clip)?.name ?? "Not assessed")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.frame(height: 170).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                TextField("Session folder name", text: $sessionName)
                HStack {
                    Button("Choose Destination…") { chooseDestination() }
                    Text(destination?.path ?? "Choose a folder on your Mac")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(destination?.path ?? "")
                }
                Toggle("Create folders from the clip-type hierarchy", isOn: $organized)
                Toggle("Group by assessment", isOn: $groupAssessments)
                Text("MP4 · Source resolution and audio · Precise trimming\nA JSON index includes categories, assessments, notes, and source times. Each export creates a new folder.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Export \(selected.count) \(selected.count == 1 ? "Clip" : "Clips")") {
                        guard let destination else { return }
                        let chosen = ClipExportSnapshot(sourceURL: snapshot.sourceURL, videoID: snapshot.videoID,
                                                        clips: snapshot.clips.filter { selected.contains($0.id) }, templates: snapshot.templates)
                        exporter.start(snapshot: chosen, destination: destination, sessionName: sessionName,
                                       organized: organized, groupAssessments: groupAssessments)
                        dismiss()
                    }.keyboardShortcut(.defaultAction)
                        .disabled(destination == nil || selected.isEmpty || sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.padding(24).frame(width: 560)
            .interactiveDismissDisabled(exporter.isRunning)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Destination"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK { destination = panel.url }
        }
    }
}
