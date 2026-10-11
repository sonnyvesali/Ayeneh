import Foundation

@MainActor
enum ReviewTemplateTests {
    static func run() throws {
        let suite = "AyenehTemplateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReviewTemplateStore(defaults: defaults)
        var draft = ReviewTemplate.draft(ownerID: store.profileID)
        draft.name = " Tennis review "
        draft.clipTypes = [ReviewOption(name: " Forehand "), ReviewOption(name: "Backhand")]
        draft.assessments = [ReviewOption(name: "Good"), ReviewOption(name: "Weak")]
        let template = try store.save(draft)
        assert(template.name == "Tennis review" && template.clipTypes[0].name == "Forehand")
        let optionID = template.clipTypes[0].id
        var edited = template
        edited.clipTypes[0].name = "Forehand groundstroke"
        edited.assessments[1].isArchived = true
        edited.color = .teal
        edited.clipTypes[0].color = .purple
        edited.assessments[0].color = .green
        _ = try store.save(edited)
        assert(store.template(template.id)?.clipTypes[0].id == optionID)
        let copy = try store.save(store.duplicateDraft(edited))
        assert(copy.id != template.id && copy.clipTypes[0].id != optionID && copy.assessments.count == 1)
        assert(copy.color == .teal && copy.clipTypes[0].color == .purple && copy.assessments[0].color == .green)
        store.setArchived(true, for: template.id)
        assert(store.activeTemplates.count == 1 && store.template(template.id) != nil)
        let reopened = ReviewTemplateStore(defaults: defaults)
        assert(reopened.profileID == store.profileID && reopened.templates.count == 2)
        assert(reopened.template(template.id)?.isArchived == true)
        assert(reopened.template(template.id)?.assessments[1].isArchived == true)
        assert(reopened.template(template.id)?.color == .teal && reopened.template(template.id)?.clipTypes[0].color == .purple)
        let encoded = try JSONEncoder().encode(edited)
        var legacyJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyJSON.removeValue(forKey: "color")
        for category in ["clipTypes", "assessments"] {
            legacyJSON[category] = (legacyJSON[category] as! [[String: Any]]).map { option in
                var option = option
                option.removeValue(forKey: "color")
                return option
            }
        }
        let legacyTemplate = try JSONDecoder().decode(ReviewTemplate.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        assert(legacyTemplate.color == nil && legacyTemplate.clipTypes.allSatisfy { $0.color == nil })
        reopened.setArchived(false, for: template.id)
        assert(reopened.activeTemplates.count == 2)
        try rejected(store, ReviewTemplate.draft(ownerID: store.profileID))
        var invalid = template
        invalid.clipTypes = [ReviewOption(name: "Forehand"), ReviewOption(name: "forehand")]
        try rejected(store, invalid)
        invalid = template
        invalid.assessments = []
        try rejected(store, invalid)
        invalid = store.duplicateDraft(template)
        invalid.name = "Tennis review"
        try rejected(store, invalid)
        var foreign = ReviewTemplate.draft(ownerID: UUID())
        foreign.name = "Foreign"
        try rejected(store, foreign)
        try hierarchy(store, defaults: defaults)
        try automaticColors(store, defaults: defaults)
        print("PASS: profile-scoped review templates, validation, stable option IDs, duplication, archive/restore, persistence")
    }

    private static func automaticColors(_ store: ReviewTemplateStore, defaults: UserDefaults) throws {
        var draft = ReviewTemplate.draft(ownerID: store.profileID)
        draft.name = "Distinct colors"
        draft.assessments = [ReviewOption(name: "Good")]
        let explicit = ReviewOption(name: "Chosen", color: .purple)
        let parent = ReviewOption(name: "Root")
        let child = ReviewOption(name: "Child", parentID: parent.id)
        draft.clipTypes = [explicit, parent, child] + (0..<12).map { ReviewOption(name: "Type \($0)") }
        let saved = try store.save(draft)
        let roots = saved.clipTypes.filter { $0.parentID == nil }
        assert(roots.allSatisfy { $0.color != nil })
        assert(Set(roots.compactMap(\.color)).count == roots.count)
        assert(saved.clipTypes.first?.color == .purple && saved.clipTypes[2].color == nil)
        let restored = ReviewTemplateStore(defaults: defaults).template(saved.id)!
        assert(restored.clipTypes.compactMap(\.color) == saved.clipTypes.compactMap(\.color))
        let copy = store.duplicateDraft(saved)
        assert(copy.clipTypes.compactMap(\.color) == saved.clipTypes.compactMap(\.color))
        var stable = saved.clipTypes
        ReviewTypeHierarchy.assignTopLevelColors(&stable)
        assert(stable.compactMap(\.color) == saved.clipTypes.compactMap(\.color))
        print("PASS: automatic distinct top-level colors, child inheritance, extended palette, stability and persistence")
    }

    private static func hierarchy(_ store: ReviewTemplateStore, defaults: UserDefaults) throws {
        let legacyData = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"Legacy type\",\"isArchived\":false}".utf8)
        let legacyOption = try JSONDecoder().decode(ReviewOption.self, from: legacyData)
        assert(legacyOption.parentID == nil && legacyOption.color == nil)
        let incoming = ReviewOption(name: "Incoming ball")
        let slow = ReviewOption(name: "Slow", parentID: incoming.id)
        let high = ReviewOption(name: "High", parentID: slow.id)
        let outgoing = ReviewOption(name: "Outgoing ball")
        let otherSlow = ReviewOption(name: "Slow", parentID: outgoing.id)
        var draft = ReviewTemplate.draft(ownerID: store.profileID)
        draft.name = "Hierarchical review"
        // Children need not be stored immediately after their parents.
        draft.clipTypes = [high, incoming, slow, outgoing, otherSlow]
        draft.assessments = [ReviewOption(name: "Good")]
        let saved = try store.save(draft)
        let rows = ReviewTypeHierarchy.rows(saved.clipTypes)
        assert(rows.map(\.id) == [incoming.id, slow.id, high.id, outgoing.id, otherSlow.id])
        assert(rows[2].depth == 2 && rows[2].path == "Incoming ball › Slow › High")
        let reopened = ReviewTemplateStore(defaults: defaults)
        assert(reopened.template(saved.id)?.clipTypes.first?.parentID == slow.id)
        let copy = try store.save(store.duplicateDraft(saved))
        let copyRows = ReviewTypeHierarchy.rows(copy.clipTypes)
        assert(copyRows.map(\.path) == rows.map(\.path))
        assert(Set(copy.clipTypes.map(\.id)).isDisjoint(with: saved.clipTypes.map(\.id)))
        assert(copyRows[2].option.parentID == copyRows[1].id)

        var archived = saved
        ReviewTypeHierarchy.archive(incoming.id, in: &archived.clipTypes)
        assert(archived.clipTypes.filter(\.isArchived).count == 3)
        _ = try store.save(archived)
        assert(ReviewTypeHierarchy.rows(archived.clipTypes).count == 2)
        let archivedCopy = store.duplicateDraft(archived)
        assert(archivedCopy.clipTypes.count == 2 && ReviewTypeHierarchy.rows(archivedCopy.clipTypes)[1].depth == 1)
        ReviewTypeHierarchy.restore(high.id, in: &archived.clipTypes)
        assert(archived.clipTypes.allSatisfy { !$0.isArchived })
        let restored = try store.save(archived)
        assert(restored.clipTypes.first?.id == high.id)

        var invalid = saved
        invalid.clipTypes[1].parentID = high.id
        try rejected(store, invalid) // Cycle.
        invalid = saved
        invalid.clipTypes[0].parentID = UUID()
        try rejected(store, invalid) // Missing parent.
        invalid = saved
        invalid.clipTypes[1].name = " "
        try rejected(store, invalid) // Blank parent with named children.
        invalid = saved
        invalid.clipTypes[1].isArchived = true
        try rejected(store, invalid) // Active child below archived parent.
        invalid = saved
        invalid.clipTypes.append(ReviewOption(name: "slow", parentID: incoming.id))
        try rejected(store, invalid) // Duplicate sibling, case insensitive.
        print("PASS: nested clip types, legacy decoding, sibling names, cycle/orphan validation, branch archive/restore, hierarchy duplication and persistence")
    }

    private static func rejected(_ store: ReviewTemplateStore, _ template: ReviewTemplate) throws {
        do {
            _ = try store.save(template)
            assertionFailure("Invalid template was saved")
        } catch is ReviewTemplateStore.ValidationError { }
    }
}
