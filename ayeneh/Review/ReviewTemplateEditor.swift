import SwiftUI

struct ReviewTemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ReviewTemplateStore
    @State private var draft: ReviewTemplate
    @State private var errorMessage: String?
    let onSave: (ReviewTemplate) -> Void

    init(store: ReviewTemplateStore, template: ReviewTemplate, onSave: @escaping (ReviewTemplate) -> Void = { _ in }) {
        self.store = store
        var template = template
        ReviewTypeHierarchy.assignTopLevelColors(&template.clipTypes)
        _draft = State(initialValue: template)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.template(draft.id) == nil ? "New Review Template" : "Edit Review Template")
                    .font(.title2.bold())
                Spacer()
            }.padding(20)
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. Tennis review"))
                    HStack {
                        Text("Template color")
                        Spacer()
                        ReviewColorPicker(color: $draft.color, label: "Template color", resetTitle: "Default blue")
                    }
                }
                Section("Clip Types") {
                    Text("Top-level types get distinct colors. Children inherit their parent's color unless overridden.")
                        .font(.caption).foregroundStyle(.secondary)
                    ReviewClipTypeEditor(options: $draft.clipTypes, templateColor: draft.color ?? .blue)
                }
                Section("Assessments") {
                    Text("Choose outcome colors here; they appear as strips beneath clips.")
                        .font(.caption).foregroundStyle(.secondary)
                    ReviewOptionEditor(options: $draft.assessments, placeholder: "e.g. Good", addTitle: "Add Assessment")
                }
            }
            .formStyle(.grouped)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            HStack {
                Text("Reusable across your videos.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Template") {
                    do {
                        let saved = try store.save(draft)
                        onSave(saved)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }.padding(20)
        }
        .frame(width: 620, height: 640)
    }
}

private struct ReviewClipTypeEditor: View {
    @Binding var options: [ReviewOption]
    let templateColor: ReviewColor

    var body: some View {
        Text("Add broad types, then use + to add more specific types beneath them.")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(ReviewTypeHierarchy.rows(options)) { row in
            if let index = options.firstIndex(where: { $0.id == row.id }) {
                HStack {
                    if row.depth > 0 {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                    }
                    TextField("Clip type", text: $options[index].name, prompt: Text(row.depth == 0 ? "e.g. Incoming ball" : "e.g. Fast"))
                        .labelsHidden().accessibilityLabel("Clip type: \(row.path)")
                    ReviewColorPicker(color: $options[index].color, label: "Color for \(row.option.name)",
                                      inheritedColor: inheritedColor(for: row.option), allowsInheritance: row.depth > 0,
                                      unavailableColors: row.depth == 0 ? Set(options.filter { $0.parentID == nil && $0.id != row.id }.compactMap(\.color)) : [])
                    Button {
                        options.append(ReviewOption(name: "", parentID: row.id))
                    } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Add child clip type")
                    .accessibilityLabel("Add child to \(row.option.name)")
                    Menu {
                        Menu("Move to") {
                            Button("Top level") {
                                options[index].parentID = nil
                                ReviewTypeHierarchy.assignTopLevelColors(&options)
                            }
                            let excluded = ReviewTypeHierarchy.branch(row.id, in: options)
                            ForEach(ReviewTypeHierarchy.rows(options).filter { !excluded.contains($0.id) }) { parent in
                                Button(parent.path.isEmpty ? "Unnamed type" : parent.path) { options[index].parentID = parent.id }
                            }
                        }
                        Button("Archive Branch") { ReviewTypeHierarchy.archive(row.id, in: &options) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).fixedSize().help("Clip type options")
                    .accessibilityLabel("Options for \(row.option.name)")
                }
                .padding(.leading, CGFloat(row.depth) * 18)
            }
        }
        Button("Add Top-Level Type", systemImage: "plus") {
            options.append(ReviewOption(name: ""))
            ReviewTypeHierarchy.assignTopLevelColors(&options)
        }
            .buttonStyle(.borderless)
        if options.contains(where: { $0.isArchived && !$0.name.isEmpty }) {
            DisclosureGroup("Archived Clip Types") {
                ForEach(options.filter { $0.isArchived && !$0.name.isEmpty }) { option in
                    HStack {
                        Text(archivedPath(option)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore") { ReviewTypeHierarchy.restore(option.id, in: &options) }
                            .buttonStyle(.borderless).help("Restore this type and its parents")
                    }
                }
            }
        }
    }

    private func inheritedColor(for option: ReviewOption) -> ReviewColor {
        var current = option.parentID
        var visited = Set<UUID>()
        while let id = current, visited.insert(id).inserted, let parent = options.first(where: { $0.id == id }) {
            if let color = parent.color { return color }
            current = parent.parentID
        }
        return templateColor
    }

    private func archivedPath(_ option: ReviewOption) -> String {
        var names = [option.name]
        var next = option.parentID
        var visited: Set<UUID> = [option.id]
        while let id = next, visited.insert(id).inserted, let parent = options.first(where: { $0.id == id }) {
            names.insert(parent.name, at: 0)
            next = parent.parentID
        }
        return names.joined(separator: " › ")
    }
}

private struct ReviewOptionEditor: View {
    @Binding var options: [ReviewOption]
    let placeholder: String
    let addTitle: String

    var body: some View {
        ForEach($options) { $option in
            if !option.isArchived {
                HStack {
                    TextField("Option", text: $option.name, prompt: Text(placeholder)).labelsHidden()
                        .accessibilityLabel("Option name")
                    ReviewColorPicker(color: $option.color, label: "Color for \(option.name)", inheritedColor: .gray,
                                      resetTitle: "Use neutral color")
                    Button { option.isArchived = true } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Archive option")
                        .accessibilityLabel("Archive \(option.name.isEmpty ? "option" : option.name)")
                }
            }
        }
        Button(addTitle, systemImage: "plus") { options.append(ReviewOption(name: "")) }
            .buttonStyle(.borderless)
        if options.contains(where: { $0.isArchived && !$0.name.isEmpty }) {
            DisclosureGroup("Archived Options") {
                ForEach($options) { $option in
                    if option.isArchived, !option.name.isEmpty {
                        HStack {
                            Text(option.name).foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore") { option.isArchived = false }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }
}
