import SwiftUI

struct ReviewTemplateLibrary: View {
    @ObservedObject var store: ReviewTemplateStore
    let onEdit: (ReviewTemplate) -> Void
    @State private var showsArchived = false

    private var templates: [ReviewTemplate] {
        store.templates.filter { showsArchived || !$0.isArchived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Toggle("Show archived", isOn: $showsArchived).toggleStyle(.checkbox)
                Spacer()
                Button("New Template", systemImage: "plus") { onEdit(.draft(ownerID: store.profileID)) }
            }.padding(.horizontal, 24)
            if templates.isEmpty {
                ContentUnavailableView {
                    Label("No Review Templates", systemImage: "rectangle.stack")
                } description: {
                    Text("Define clip types and assessments once, then reuse them across your videos.")
                } actions: {
                    Button("Create Template") { onEdit(.draft(ownerID: store.profileID)) }
                }
            } else {
                List(templates) { template in
                    HStack(spacing: 16) {
                        Image(systemName: "rectangle.stack").font(.title2).foregroundStyle((template.color ?? .blue).swatch)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(template.name).font(.headline)
                                if template.isArchived { Text("Archived").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text("\(template.clipTypes.filter { !$0.isArchived }.count) clip types · \(template.assessments.filter { !$0.isArchived }.count) assessments")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(ReviewTypeHierarchy.rows(template.clipTypes).map(\.path).joined(separator: ", "))
                                .font(.caption).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { onEdit(template) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit \(template.name)")
                        Menu {
                            Button("Duplicate…") { onEdit(store.duplicateDraft(template)) }
                            Button(template.isArchived ? "Restore Template" : "Archive Template") {
                                store.setArchived(!template.isArchived, for: template.id)
                            }
                        } label: { Image(systemName: "ellipsis") }
                        .menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Options for \(template.name)")
                    }.padding(.vertical, 10)
                }.listStyle(.inset)
            }
        }
    }
}
