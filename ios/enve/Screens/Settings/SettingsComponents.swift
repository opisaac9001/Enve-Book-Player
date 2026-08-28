import SwiftUI

struct SettingsScaffold<Content: View>: View {
    let overline: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
                    VStack(alignment: .leading, spacing: 6) {
                        Overline(overline)
                        Text(title)
                            .font(.hearthScreenTitle)
                            .foregroundStyle(hearth.text)
                        if let subtitle {
                            Text(subtitle)
                                .font(.hearthBody)
                                .foregroundStyle(hearth.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                content
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct SettingsLinkRow: View {
    let title: String
    var subtitle: String? = nil
    var detail: String? = nil
    var systemImage: String? = nil

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.ember)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(hearth.ember.opacity(0.14)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.hearthBody.weight(.medium))
                    .foregroundStyle(hearth.text)
                    .accessibilityHidden(true)
                if let subtitle {
                    Text(subtitle)
                        .font(.hearthCaption.weight(.medium))
                        .foregroundStyle(hearth.text)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.hearthCaption.weight(.medium))
                    .foregroundStyle(hearth.text)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.hearthUI(12, weight: .semibold))
                .foregroundStyle(hearth.textTertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        [subtitle, detail].compactMap { $0 }.joined(separator: ". ")
    }
}

struct SettingsChoiceRow: View {
    let title: String
    var caption: String? = nil
    var systemImage: String? = nil
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.hearthUI(15))
                        .foregroundStyle(isSelected ? hearth.ember : hearth.textSecondary)
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                    if let caption {
                        Text(caption)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textTertiary)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? hearth.ember : hearth.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct SettingsMenuRow<Choices: View>: View {
    let title: String
    let value: String
    @ViewBuilder var choices: Choices

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack {
            Text(title)
                .font(.hearthBody)
                .foregroundStyle(hearth.text)
            Spacer()
            Menu {
                choices
            } label: {
                HStack(spacing: 5) {
                    Text(value)
                        .font(.hearthUI(15, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.hearthUI(10, weight: .semibold))
                }
                .foregroundStyle(hearth.ember)
            }
        }
    }
}

enum SettingsPrefs {
    @discardableResult
    static func mutate(_ change: (inout UserPreferences) -> Void) -> UserPreferences {
        var prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
        change(&prefs)
        LibraryDisplayPreferencesStore.shared.savePreferences(prefs)
        Theme.currentPreferences = prefs
        return prefs
    }
}
