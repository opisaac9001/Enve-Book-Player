import PhotosUI
import SwiftUI
import UIKit

struct CollectionsEditorSheet: View {
    var collection: Collection?
    var smartCollection: SmartCollection?

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var details: String
    @State private var iconName: String
    @State private var selectedColor: String
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var rules: [SmartCollectionRule]
    @State private var logicOperator: LogicOperator
    @State private var ruleBuilderShown = false
    @State private var deleteConfirmShown = false

    private let isSmart: Bool

    private static let colors = ["blue", "red", "green", "orange", "purple", "pink", "teal", "gray"]
    private static let icons = [
        "folder.fill", "books.vertical.fill", "star.fill", "heart.fill",
        "bookmark.fill", "tag.fill", "headphones", "book.fill",
        "flame.fill", "moon.fill", "sparkles", "tray.fill",
    ]

    init(collection: Collection? = nil, smartCollection: SmartCollection? = nil, isSmart: Bool = false) {
        self.collection = collection
        self.smartCollection = smartCollection
        self.isSmart = smartCollection != nil || isSmart
        _name = State(initialValue: collection?.name ?? smartCollection?.name ?? "")
        _details = State(initialValue: collection?.description ?? smartCollection?.description ?? "")
        _iconName = State(initialValue: collection?.iconName ?? smartCollection?.iconName ?? "folder.fill")
        _selectedColor = State(initialValue: collection?.color ?? smartCollection?.color ?? "blue")
        _rules = State(initialValue: smartCollection?.rules.rules ?? [])
        _logicOperator = State(initialValue: smartCollection?.rules.logicOperator ?? .and)
    }

    private var isExisting: Bool { collection != nil || smartCollection != nil }
    private var isDeletable: Bool {
        (collection.map { !$0.isSystem } ?? false) || (smartCollection.map { !$0.isSystem } ?? false)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (!isSmart || !rules.isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Overline(isSmart ? "Smart shelf" : "Shelf")
                    Text(titleLine)
                        .font(.hearthDisplay(24, weight: .semibold))
                        .foregroundStyle(hearth.text)
                }
                .padding(.top, 24)

                VStack(alignment: .leading, spacing: 12) {
                    Overline("Name")
                    collectionsField("A name for the shelf", text: $name)
                    collectionsField("A line about it, if you like", text: $details)
                }

                coverRow
                iconRow
                colorRow

                if isSmart {
                    rulesSection
                } else {
                    Text("Add books to this shelf from their own pages.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }

                HStack(spacing: 12) {
                    QuietButton(title: "Cancel") { dismiss() }
                    EmberButton(title: isExisting ? "Keep changes" : "Create") {
                        save()
                        dismiss()
                    }
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
                }

                if isDeletable {
                    Button {
                        deleteConfirmShown = true
                    } label: {
                        Text("Delete this shelf")
                            .font(.hearthUI(15, weight: .medium))
                            .foregroundStyle(hearth.statusError)
                            .frame(minHeight: 44)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .hearthPresentationBackground()
        .presentationDragIndicator(.visible)
        .onChange(of: selectedItem) { _, newValue in
            Task {
                if let data = try? await newValue?.loadTransferable(type: Data.self) {
                    selectedImageData = data
                }
            }
        }
        .sheet(isPresented: $ruleBuilderShown) {
            CollectionsRuleBuilderSheet(rules: $rules)
                .enveEnvironment()
        }
        .confirmationDialog("Delete this shelf?", isPresented: $deleteConfirmShown, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                engine.library.deleteCollection(collection: collection, smartCollection: smartCollection)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The books stay in the library; only the shelf goes.")
        }
    }

    private var titleLine: String {
        if isSmart { return smartCollection == nil ? "A shelf that fills itself" : "Edit the rules" }
        return collection == nil ? "A shelf of your choosing" : "Edit the shelf"
    }

    private var coverRow: some View {
        let imageData = selectedImageData
        let coverPath = collection?.customCoverPath ?? smartCollection?.customCoverPath
        let palette = hearth
        return VStack(alignment: .leading, spacing: 12) {
            Overline("Cover")
            HStack(spacing: 14) {
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    CollectionsCoverPickerLabel(imageData: imageData, coverPath: coverPath, palette: palette)
                }
                .accessibilityLabel("Choose a custom cover")
                Text("A picture of your own, if the books shouldn't speak for it.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
    }

    private var iconRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Overline("Mark")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 10)], spacing: 10) {
                ForEach(Self.icons, id: \.self) { icon in
                    Button {
                        iconName = icon
                    } label: {
                        Image(systemName: icon)
                            .font(.hearthUI(17))
                            .foregroundStyle(iconName == icon ? hearth.onEmber : hearth.textSecondary)
                            .frame(width: 48, height: 44)
                            .background {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(iconName == icon ? hearth.ember : hearth.bg)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(hearth.hairline, lineWidth: 1)
                                    }
                            }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(icon)
                }
            }
        }
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Overline("Color")
            HStack(spacing: 12) {
                ForEach(Self.colors, id: \.self) { color in
                    Button {
                        selectedColor = color
                    } label: {
                        Circle()
                            .fill(collectionsTint(color))
                            .frame(width: 30, height: 30)
                            .overlay {
                                if selectedColor == color {
                                    Circle().strokeBorder(hearth.text, lineWidth: 2)
                                }
                            }
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(color)
                }
            }
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Overline("Rules")
            HStack(spacing: 10) {
                HearthChip(title: "Match every rule", isSelected: logicOperator == .and) {
                    logicOperator = .and
                }
                HearthChip(title: "Match any rule", isSelected: logicOperator == .or) {
                    logicOperator = .or
                }
            }

            if rules.isEmpty {
                Text("No rules yet. The shelf stays empty until you give it one.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.field.displayName)
                                    .font(.hearthUI(15, weight: .semibold))
                                    .foregroundStyle(hearth.text)
                                Text("\(rule.operator.displayName) \(rule.value)")
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textSecondary)
                            }
                            Spacer()
                            GlyphButton(systemImage: "trash", size: 40, glyphSize: 14, label: "Remove rule") {
                                rules.remove(at: index)
                            }
                        }
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(hearth.bg)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(hearth.hairline, lineWidth: 1)
                                }
                        }
                    }
                }
            }

            QuietButton(title: "Add a rule", systemImage: "plus") {
                ruleBuilderShown = true
            }
        }
    }

    private func collectionsField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.hearthBody)
            .foregroundStyle(hearth.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hearth.bg)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
    }

    private func save() {
        engine.library.saveCollection(
            collection: collection,
            smartCollection: smartCollection,
            isSmart: isSmart,
            values: CollectionEditorValues(
                name: name,
                details: details,
                iconName: iconName,
                color: selectedColor,
                selectedImageData: selectedImageData,
                rules: rules,
                logicOperator: logicOperator
            )
        )
        PlatformHaptics.notification(.success)
    }
}

struct CollectionsRuleBuilderSheet: View {
    @Binding var rules: [SmartCollectionRule]

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var field: SmartCollectionField = .progress
    @State private var op: SmartCollectionOperator = .greaterThan
    @State private var value = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Overline("Smart shelf")
                    Text("Add a rule")
                        .font(.hearthDisplay(24, weight: .semibold))
                        .foregroundStyle(hearth.text)
                }
                .padding(.top, 24)

                VStack(alignment: .leading, spacing: 12) {
                    Overline("Field")
                    collectionsMenuRow(title: field.displayName) {
                        ForEach(SmartCollectionField.allCases, id: \.self) { candidate in
                            Button(candidate.displayName) { field = candidate }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Overline("Condition")
                    collectionsMenuRow(title: op.displayName) {
                        ForEach(SmartCollectionOperator.allCases, id: \.self) { candidate in
                            Button(candidate.displayName) { op = candidate }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Overline("Value")
                    TextField("Value", text: $value)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                        .keyboardType(field == .progress || field == .duration ? .decimalPad : .default)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(hearth.bg)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(hearth.hairline, lineWidth: 1)
                                }
                        }
                    Text(valueHint)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }

                HStack(spacing: 12) {
                    QuietButton(title: "Cancel") { dismiss() }
                    EmberButton(title: "Add rule") {
                        rules.append(SmartCollectionRule(field: field, operator: op, value: value))
                        dismiss()
                    }
                    .disabled(value.isEmpty)
                    .opacity(value.isEmpty ? 0.5 : 1)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .presentationDetents([.large, .medium])
        .hearthPresentationBackground()
    }

    private var valueHint: String {
        switch field {
        case .progress: "0.0 to 1.0. 0.5 means halfway."
        case .duration: "Hours. 10 means ten hours."
        case .isFinished, .isDownloaded, .isAbandoned: "true or false"
        case .dateAdded, .lastPlayed: "Days ago. 30 means the last month."
        default: "Text to match"
        }
    }

    private func collectionsMenuRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack {
                Text(title)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.hearthUI(12))
                    .foregroundStyle(hearth.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hearth.bg)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
        }
    }
}

struct CollectionsCoverPickerLabel: View {
    let imageData: Data?
    let coverPath: String?
    let hearth: HearthPalette

    nonisolated init(imageData: Data?, coverPath: String?, palette: HearthPalette) {
        self.imageData = imageData
        self.coverPath = coverPath
        hearth = palette
    }

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let coverPath, let image = UIImage(contentsOfFile: coverPath) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                        .fill(hearth.emberSoft)
                    Image(systemName: "photo")
                        .font(.hearthUI(20))
                        .foregroundStyle(hearth.ember)
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                .strokeBorder(hearth.hairline, lineWidth: 1)
        }
    }
}
