import Combine
import Foundation

struct ReviewColor: RawRepresentable, Codable, CaseIterable, Hashable, Identifiable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let blue = Self(rawValue: "blue")
    static let teal = Self(rawValue: "teal")
    static let green = Self(rawValue: "green")
    static let yellow = Self(rawValue: "yellow")
    static let orange = Self(rawValue: "orange")
    static let red = Self(rawValue: "red")
    static let pink = Self(rawValue: "pink")
    static let purple = Self(rawValue: "purple")
    static let gray = Self(rawValue: "gray")
    static let allCases: [Self] = [.blue, .orange, .green, .purple, .red, .teal, .pink, .yellow, .gray]
    var id: String { rawValue }
    var name: String { rawValue.hasPrefix("#") ? rawValue : rawValue.capitalized }

    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func nextUnused(excluding used: Set<Self>) -> Self {
        if let color = allCases.first(where: { !used.contains($0) }) { return color }
        // Extend the palette with distinct hues for larger taxonomies.
        for index in 0...65535 {
            let hue = (Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1) * 6
            let sector = Int(hue)
            let fraction = hue - Double(sector)
            let value = 0.78
            let low = value * 0.28
            let rising = low + (value - low) * fraction
            let falling = value - (value - low) * fraction
            let rgb: (Double, Double, Double)
            switch sector {
            case 0: rgb = (value, rising, low)
            case 1: rgb = (falling, value, low)
            case 2: rgb = (low, value, rising)
            case 3: rgb = (low, falling, value)
            case 4: rgb = (rising, low, value)
            default: rgb = (value, low, falling)
            }
            let color = Self(rawValue: String(format: "#%02X%02X%02X", Int(rgb.0 * 255), Int(rgb.1 * 255), Int(rgb.2 * 255)))
            if !used.contains(color) { return color }
        }
        return .blue
    }
}

struct ReviewOption: Codable, Identifiable {
    var id = UUID()
    var name: String
    var isArchived = false
    var parentID: UUID?
    var color: ReviewColor?
}

struct ReviewTypeRow: Identifiable {
    let option: ReviewOption
    let depth: Int
    let path: String
    var id: UUID { option.id }
}

enum ReviewTypeHierarchy {
    static func assignTopLevelColors(_ options: inout [ReviewOption]) {
        var used = Set(options.filter { $0.parentID == nil }.compactMap(\.color))
        for index in options.indices where options[index].parentID == nil && options[index].color == nil {
            let color = ReviewColor.nextUnused(excluding: used)
            options[index].color = color
            used.insert(color)
        }
    }

    static func rows(_ options: [ReviewOption]) -> [ReviewTypeRow] {
        var result: [ReviewTypeRow] = []
        var visited = Set<UUID>()
        func appendChildren(of parentID: UUID?, depth: Int, path: String) {
            for option in options where option.parentID == parentID && !option.isArchived {
                guard visited.insert(option.id).inserted else { continue }
                let nextPath = path.isEmpty ? option.name : "\(path) › \(option.name)"
                result.append(ReviewTypeRow(option: option, depth: depth, path: nextPath))
                appendChildren(of: option.id, depth: depth + 1, path: nextPath)
            }
        }
        appendChildren(of: nil, depth: 0, path: "")
        return result
    }

    static func branch(_ id: UUID, in options: [ReviewOption]) -> Set<UUID> {
        var ids: Set<UUID> = [id]
        var previousCount = 0
        while previousCount != ids.count {
            previousCount = ids.count
            for option in options {
                if let parent = option.parentID, ids.contains(parent) { ids.insert(option.id) }
            }
        }
        return ids
    }

    static func archive(_ id: UUID, in options: inout [ReviewOption]) {
        let ids = branch(id, in: options)
        for index in options.indices where ids.contains(options[index].id) { options[index].isArchived = true }
    }

    static func restore(_ id: UUID, in options: inout [ReviewOption]) {
        var next: UUID? = id
        var visited = Set<UUID>()
        while let current = next, visited.insert(current).inserted,
              let index = options.firstIndex(where: { $0.id == current }) {
            options[index].isArchived = false
            next = options[index].parentID
        }
    }
}

struct ReviewTemplate: Codable, Identifiable {
    var id = UUID()
    let ownerID: UUID
    var name: String
    var clipTypes: [ReviewOption]
    var assessments: [ReviewOption]
    var isArchived = false
    var updatedAt = Date()
    var color: ReviewColor?

    static func draft(ownerID: UUID) -> Self {
        Self(ownerID: ownerID, name: "", clipTypes: [ReviewOption(name: "", color: .blue)], assessments: [ReviewOption(name: "")])
    }
}

@MainActor
final class ReviewTemplateStore: ObservableObject {
    @Published private(set) var templates: [ReviewTemplate] = []
    let profileID: UUID
    private let defaults: UserDefaults
    private let key = "reviewTemplateLibrary.v1"

    private struct Library: Codable {
        var profileID: UUID
        var templates: [ReviewTemplate]
    }

    struct ValidationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let library = try? JSONDecoder().decode(Library.self, from: data) {
            profileID = library.profileID
            templates = library.templates.filter { $0.ownerID == library.profileID }
            for index in templates.indices { ReviewTypeHierarchy.assignTopLevelColors(&templates[index].clipTypes) }
        } else {
            profileID = UUID()
        }
        persist()
    }

    var activeTemplates: [ReviewTemplate] {
        templates.filter { !$0.isArchived }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func template(_ id: UUID?) -> ReviewTemplate? { templates.first { $0.id == id } }

    @discardableResult
    func save(_ draft: ReviewTemplate) throws -> ReviewTemplate {
        guard draft.ownerID == profileID else { throw ValidationError(message: "This template belongs to another profile.") }
        var template = draft
        template.name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.name.isEmpty else { throw ValidationError(message: "Give the template a name.") }
        guard !templates.contains(where: { $0.id != template.id && $0.name.lowercased() == template.name.lowercased() }) else {
            throw ValidationError(message: "A template with that name already exists.")
        }
        template.clipTypes = try clean(template.clipTypes, category: "clip type", hierarchical: true)
        ReviewTypeHierarchy.assignTopLevelColors(&template.clipTypes)
        template.assessments = try clean(template.assessments, category: "assessment")
        template.updatedAt = Date()
        if let index = templates.firstIndex(where: { $0.id == template.id }) { templates[index] = template }
        else { templates.append(template) }
        persist()
        return template
    }

    func setArchived(_ archived: Bool, for id: UUID) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[index].isArchived = archived
        templates[index].updatedAt = Date()
        persist()
    }

    func duplicateDraft(_ template: ReviewTemplate) -> ReviewTemplate {
        var copy = template
        copy.id = UUID()
        var name = "\(template.name) Copy"
        var number = 2
        while templates.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            name = "\(template.name) Copy \(number)"
            number += 1
        }
        copy.name = name
        copy.isArchived = false
        let activeTypes = template.clipTypes.filter { !$0.isArchived }
        let newIDs = Dictionary(uniqueKeysWithValues: activeTypes.map { ($0.id, UUID()) })
        copy.clipTypes = activeTypes.map {
            ReviewOption(id: newIDs[$0.id]!, name: $0.name, parentID: $0.parentID.flatMap { newIDs[$0] }, color: $0.color)
        }
        copy.assessments = template.assessments.filter { !$0.isArchived }.map { ReviewOption(name: $0.name, color: $0.color) }
        return copy
    }

    private func clean(_ options: [ReviewOption], category: String, hierarchical: Bool = false) throws -> [ReviewOption] {
        let cleaned = options.compactMap { option -> ReviewOption? in
            var option = option
            option.name = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return option.name.isEmpty ? nil : option
        }
        let names = cleaned.filter { !$0.isArchived }.map { $0.name.lowercased() }
        guard !names.isEmpty else { throw ValidationError(message: "Add at least one \(category).") }
        guard Set(cleaned.map(\.id)).count == cleaned.count else { throw ValidationError(message: "Each option needs its own identity.") }
        if hierarchical {
            let byID = Dictionary(uniqueKeysWithValues: cleaned.map { ($0.id, $0) })
            for option in cleaned {
                var visited: Set<UUID> = [option.id]
                var parentID = option.parentID
                while let id = parentID {
                    guard let parent = byID[id] else { throw ValidationError(message: "Name every parent clip type before saving.") }
                    guard visited.insert(id).inserted else { throw ValidationError(message: "Clip types cannot contain a circular hierarchy.") }
                    guard option.isArchived || !parent.isArchived else { throw ValidationError(message: "Restore the parent clip type before using its children.") }
                    parentID = parent.parentID
                }
            }
            let groups = Dictionary(grouping: cleaned.filter { !$0.isArchived }, by: \.parentID)
            for siblings in groups.values {
                let siblingNames = siblings.map { $0.name.lowercased() }
                guard Set(siblingNames).count == siblingNames.count else { throw ValidationError(message: "Clip types under the same parent need unique names.") }
            }
        } else {
            guard cleaned.allSatisfy({ $0.parentID == nil }) else { throw ValidationError(message: "Assessments must be flat options.") }
            guard Set(names).count == names.count else { throw ValidationError(message: "Each \(category) needs a unique name.") }
        }
        return cleaned
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Library(profileID: profileID, templates: templates)) {
            defaults.set(data, forKey: key)
        }
    }
}
