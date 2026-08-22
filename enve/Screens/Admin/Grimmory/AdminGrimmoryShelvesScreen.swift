import SwiftUI

struct AdminGrimmoryShelvesScreen: View {
    let model: AdminGrimmoryModel

    @Environment(\.hearth) private var hearth
    @State private var showingAddShelf = false
    @State private var showingAddMagicShelf = false
    @State private var editingShelf: GrimmoryShelf?
    @State private var editingMagicShelf: GrimmoryMagicShelf?
    @State private var deletingShelf: GrimmoryShelf?
    @State private var deletingMagicShelf: GrimmoryMagicShelf?

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Shelves") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                AdminActionTile(title: "New shelf", systemImage: "plus.rectangle.on.folder") {
                    showingAddShelf = true
                }
                AdminActionTile(title: "New magic shelf", systemImage: "wand.and.stars") {
                    showingAddMagicShelf = true
                }
            }

            SourcesCard {
                Overline("Shelves · \(model.shelves.count)")
                if model.shelves.isEmpty {
                    AdminEmptyText(
                        model.isLoading
                            ? "Fetching the shelves…"
                            : "No shelves yet. Build one to gather books by hand."
                    )
                } else {
                    ForEach(model.shelves) { shelf in
                        adminShelfRow(shelf)
                    }
                }
            }

            SourcesCard {
                Overline("Magic shelves · \(model.magicShelves.count)")
                if model.magicShelves.isEmpty {
                    AdminEmptyText("No magic shelves yet. They fill themselves from rules you write.")
                } else {
                    ForEach(model.magicShelves) { shelf in
                        adminMagicShelfRow(shelf)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddShelf) {
            AdminGrimmoryShelfSheet(model: model, editing: nil)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .sheet(item: $editingShelf) { shelf in
            AdminGrimmoryShelfSheet(model: model, editing: shelf)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .sheet(isPresented: $showingAddMagicShelf) {
            AdminGrimmoryMagicShelfSheet(model: model, existing: nil)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .sheet(item: $editingMagicShelf) { shelf in
            AdminGrimmoryMagicShelfSheet(model: model, existing: shelf)
                .enveEnvironment()
                .hearthPresentationBackground()
        }
        .alert(
            "Take down this shelf",
            isPresented: Binding(
                get: { deletingShelf != nil },
                set: { if !$0 { deletingShelf = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let shelf = deletingShelf {
                    Task { await model.deleteShelf(id: shelf.id) }
                }
                deletingShelf = nil
            }
            Button("Cancel", role: .cancel) { deletingShelf = nil }
        } message: {
            Text("“\(deletingShelf?.name ?? "")” will be gone. The books stay where they are.")
        }
        .alert(
            "Dispel this magic shelf",
            isPresented: Binding(
                get: { deletingMagicShelf != nil },
                set: { if !$0 { deletingMagicShelf = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let id = deletingMagicShelf?.id {
                    Task { await model.deleteMagicShelf(id: id) }
                }
                deletingMagicShelf = nil
            }
            Button("Cancel", role: .cancel) { deletingMagicShelf = nil }
        } message: {
            Text("“\(deletingMagicShelf?.name ?? "")” and its rules will be gone.")
        }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
    }

    private func adminShelfRow(_ shelf: GrimmoryShelf) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.ember)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(shelf.name)
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                HStack(spacing: 6) {
                    if let count = shelf.bookCount {
                        Text("\(count) books")
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                    }
                    if shelf.publicShelf == true {
                        AdminTag(text: "Public", color: hearth.statusOK)
                    }
                }
            }
            Spacer()
            Menu {
                Button {
                    editingShelf = shelf
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    deletingShelf = shelf
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.hearthUI(14, weight: .semibold))
                    .foregroundStyle(hearth.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(shelf.name)")
        }
        .frame(minHeight: 44)
    }

    private func adminMagicShelfRow(_ shelf: GrimmoryMagicShelf) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.ember)
                .frame(width: 24)
            Text(shelf.name)
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.text)
            if shelf.isPublic == true {
                AdminTag(text: "Public", color: hearth.statusOK)
            }
            Spacer()
            Menu {
                Button {
                    editingMagicShelf = shelf
                } label: {
                    Label("Edit the rules", systemImage: "slider.horizontal.3")
                }
                Divider()
                Button(role: .destructive) {
                    deletingMagicShelf = shelf
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.hearthUI(14, weight: .semibold))
                    .foregroundStyle(hearth.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(shelf.name)")
        }
        .frame(minHeight: 44)
    }
}

private struct AdminGrimmoryShelfSheet: View {
    let model: AdminGrimmoryModel
    let editing: GrimmoryShelf?

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var icon: String
    @State private var isPublic: Bool

    init(model: AdminGrimmoryModel, editing: GrimmoryShelf?) {
        self.model = model
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _icon = State(initialValue: editing?.icon ?? "")
        _isPublic = State(initialValue: editing?.publicShelf ?? false)
    }

    var body: some View {
        AdminSheet(
            title: editing == nil ? "A new shelf" : editing!.name,
            confirmTitle: editing == nil ? "Create" : "Save",
            confirmDisabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onConfirm: {
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedIcon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    if let editing {
                        await model.updateShelf(
                            id: editing.id,
                            name: trimmedName,
                            icon: trimmedIcon.isEmpty ? nil : trimmedIcon,
                            isPublic: isPublic
                        )
                    } else {
                        await model.createShelf(
                            name: trimmedName,
                            icon: trimmedIcon.isEmpty ? nil : trimmedIcon,
                            isPublic: isPublic
                        )
                    }
                }
                dismiss()
            }
        ) {
            SourcesField(label: "Name", text: $name)
            SourcesField(label: "Icon (optional, e.g. pi-book)", text: $icon)
            SourcesToggleRow(
                title: "Public shelf",
                subtitle: "Public shelves are visible to everyone on the server.",
                isOn: $isPublic
            )
            Text("Icons use PrimeNG names, like pi-book and pi-star.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
    }
}

private struct AdminGrimmoryMagicShelfSheet: View {
    let model: AdminGrimmoryModel
    let existing: GrimmoryMagicShelf?

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var icon: String
    @State private var isPublic: Bool
    @State private var joinType: String
    @State private var rules: [MagicShelfRule]

    init(model: AdminGrimmoryModel, existing: GrimmoryMagicShelf?) {
        self.model = model
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _icon = State(initialValue: existing?.icon ?? "")
        _isPublic = State(initialValue: existing?.isPublic ?? false)

        var parsedJoin = "and"
        var parsedRules = [MagicShelfRule(field: "title", op: "contains", value: "")]
        if let existing, let data = existing.filterJson.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            parsedJoin = parsed["join"] as? String ?? "and"
            if let rulesArray = parsed["rules"] as? [[String: Any]] {
                let mapped = rulesArray.compactMap { dict -> MagicShelfRule? in
                    guard let field = dict["field"] as? String,
                        let op = dict["operator"] as? String
                    else { return nil }
                    return MagicShelfRule(
                        field: field,
                        op: op,
                        value: dict["value"].map { "\($0)" },
                        valueStart: dict["valueStart"].map { "\($0)" },
                        valueEnd: dict["valueEnd"].map { "\($0)" }
                    )
                }
                if !mapped.isEmpty { parsedRules = mapped }
            }
        }
        _joinType = State(initialValue: parsedJoin)
        _rules = State(initialValue: parsedRules)
    }

    var body: some View {
        AdminSheet(
            title: existing == nil ? "A new magic shelf" : existing!.name,
            confirmTitle: "Save",
            confirmDisabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rules.isEmpty,
            onConfirm: adminSave
        ) {
            SourcesField(label: "Name", text: $name)
            SourcesField(label: "Icon (optional, e.g. pi-book)", text: $icon)
            SourcesToggleRow(title: "Public", isOn: $isPublic)

            VStack(alignment: .leading, spacing: 7) {
                Overline("A book belongs when it matches")
                HStack(spacing: 8) {
                    HearthChip(title: "All rules", isSelected: joinType == "and") { joinType = "and" }
                    HearthChip(title: "Any rule", isSelected: joinType == "or") { joinType = "or" }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Overline("Rules")
                ForEach($rules) { $rule in
                    adminRuleEditor($rule)
                }
                QuietButton(title: "Add a rule", systemImage: "plus") {
                    rules.append(MagicShelfRule(field: "title", op: "contains", value: ""))
                }
            }

            Text("The server reads these rules and keeps the shelf filled on its own.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Overline("Quick starts")
                adminPresetRow("Currently reading", glyph: "book") {
                    adminApplyPreset(
                        "Currently reading",
                        [
                            MagicShelfRule(field: "readStatus", op: "equals", value: "IN_PROGRESS")
                        ]
                    )
                }
                adminPresetRow("Unread books", glyph: "book.closed") {
                    adminApplyPreset(
                        "Unread books",
                        [
                            MagicShelfRule(field: "readStatus", op: "equals", value: "UNREAD")
                        ]
                    )
                }
                adminPresetRow("All audiobooks", glyph: "headphones") {
                    adminApplyPreset(
                        "Audiobooks",
                        [
                            MagicShelfRule(field: "fileType", op: "equals", value: "AUDIOBOOK")
                        ]
                    )
                }
                adminPresetRow("Added in the last thirty days", glyph: "clock") {
                    adminApplyPreset(
                        "Recently added",
                        [
                            MagicShelfRule(field: "addedOn", op: "within_last", value: "30")
                        ]
                    )
                }
                adminPresetRow("Highly rated (four stars up)", glyph: "star") {
                    adminApplyPreset(
                        "Highly rated",
                        [
                            MagicShelfRule(field: "goodreadsRating", op: "greater_than_equal_to", value: "4.0")
                        ]
                    )
                }
                adminPresetRow("Long audiobooks (twenty hours up)", glyph: "timer") {
                    adminApplyPreset(
                        "Long audiobooks",
                        [
                            MagicShelfRule(field: "fileType", op: "equals", value: "AUDIOBOOK"),
                            MagicShelfRule(field: "audiobookDuration", op: "greater_than", value: "72000000"),
                        ]
                    )
                }
            }
        }
    }

    private func adminRuleEditor(_ rule: Binding<MagicShelfRule>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(MagicShelfField.groupedFields, id: \.group) { group in
                        Section(group.group) {
                            ForEach(group.fields) { field in
                                Button(field.displayName) {
                                    rule.wrappedValue.field = field.rawValue
                                }
                            }
                        }
                    }
                } label: {
                    adminMenuLabel(
                        MagicShelfField(rawValue: rule.wrappedValue.field)?.displayName ?? rule.wrappedValue.field
                    )
                }
                Spacer()
                Button {
                    rules.removeAll { $0.id == rule.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.hearthUI(15))
                        .foregroundStyle(hearth.statusError)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Remove this rule")
            }

            if let field = MagicShelfField(rawValue: rule.wrappedValue.field) {
                Menu {
                    ForEach(MagicShelfOperator.applicableOperators(for: field)) { op in
                        Button(op.displayName) {
                            rule.wrappedValue.op = op.rawValue
                        }
                    }
                } label: {
                    adminMenuLabel(
                        MagicShelfOperator(rawValue: rule.wrappedValue.op)?.displayName ?? rule.wrappedValue.op
                    )
                }
            }

            let op = rule.wrappedValue.op
            if op != "is_empty", op != "is_not_empty" {
                if op == "in_between" {
                    HStack(spacing: 8) {
                        SourcesField(
                            label: "From",
                            text: Binding(
                                get: { rule.wrappedValue.valueStart ?? "" },
                                set: { rule.wrappedValue.valueStart = $0 }
                            )
                        )
                        SourcesField(
                            label: "To",
                            text: Binding(
                                get: { rule.wrappedValue.valueEnd ?? "" },
                                set: { rule.wrappedValue.valueEnd = $0 }
                            )
                        )
                    }
                } else {
                    SourcesField(
                        label: "Value",
                        text: Binding(
                            get: { rule.wrappedValue.value ?? "" },
                            set: { rule.wrappedValue.value = $0 }
                        )
                    )
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hearth.bg)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
        }
    }

    private func adminMenuLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.text)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.hearthUI(10, weight: .semibold))
                .foregroundStyle(hearth.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            Capsule()
                .fill(hearth.bgElevated)
                .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
        }
    }

    private func adminPresetRow(_ title: String, glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: glyph)
                    .font(.hearthUI(13, weight: .medium))
                    .foregroundStyle(hearth.ember)
                    .frame(width: 22)
                Text(title)
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                Spacer()
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func adminApplyPreset(_ presetName: String, _ presetRules: [MagicShelfRule]) {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = presetName
        }
        rules = presetRules
    }

    private func adminSave() {
        let trimmedIcon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        let shelf = GrimmoryMagicShelf(
            id: existing?.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: trimmedIcon.isEmpty ? nil : trimmedIcon,
            iconType: trimmedIcon.isEmpty ? nil : "PRIME_NG",
            filterJson: GrimmoryMagicShelf.buildFilterJson(join: joinType, rules: rules),
            isPublic: isPublic
        )
        Task { await model.saveMagicShelf(shelf) }
        dismiss()
    }
}
