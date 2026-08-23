import SwiftUI

struct HomePreferencesScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss

    @State private var preferences = LibraryDisplayPreferencesStore.shared.loadPreferences()

    private var order: [UserPreferences.HomeSection] {
        preferences.normalizedHomeSectionOrder
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                VStack(alignment: .leading, spacing: 12) {
                    Overline("When Enve opens")
                    SourcesCard {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.right.to.line")
                                .foregroundStyle(hearth.ember)
                                .frame(width: 24)
                            Text("Start on")
                                .font(.hearthBody)
                                .foregroundStyle(hearth.text)
                            Spacer()
                            Picker("Start on", selection: $preferences.preferredStartTab) {
                                ForEach(UserPreferences.PreferredStartTab.allCases) { tab in
                                    Text(tab.displayName).tag(tab)
                                }
                            }
                            .labelsHidden()
                            .tint(hearth.ember)
                            .onChange(of: preferences.preferredStartTab) { _, _ in save() }
                        }
                    }
                    Text("The new tab is used the next time Enve launches.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Overline("Hearth shelf order")
                        Spacer()
                        Button("Reset") {
                            withAnimation(.snappy) {
                                preferences.homeSectionOrder = UserPreferences.HomeSection.allCases
                                save()
                            }
                        }
                        .font(.hearthCaption.weight(.semibold))
                        .foregroundStyle(hearth.ember)
                    }

                    SourcesCard {
                        ForEach(order.indices, id: \.self) { index in
                            let section = order[index]
                            HStack(spacing: 12) {
                                Image(systemName: section.glyph)
                                    .font(.hearthUI(15, weight: .medium))
                                    .foregroundStyle(hearth.ember)
                                    .frame(width: 24)

                                Text(section.displayName)
                                    .font(.hearthBody)
                                    .foregroundStyle(hearth.text)

                                Spacer()

                                Button {
                                    move(section, by: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(index == 0 ? hearth.textTertiary : hearth.textSecondary)
                                .disabled(index == 0)
                                .accessibilityLabel("Move \(section.displayName) up")

                                Button {
                                    move(section, by: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(index == order.count - 1 ? hearth.textTertiary : hearth.textSecondary)
                                .disabled(index == order.count - 1)
                                .accessibilityLabel("Move \(section.displayName) down")
                            }
                        }
                    }

                    Text("Only shelves with books appear. The hero and reading pulse stay at the top.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") {
                dismiss()
            }
            VStack(alignment: .leading, spacing: 6) {
                Overline("Playback & experience")
                Text("Home & startup")
                    .font(.hearthScreenTitle)
                    .foregroundStyle(hearth.text)
            }
            Spacer(minLength: 0)
        }
    }

    private func move(_ section: UserPreferences.HomeSection, by offset: Int) {
        var updated = order
        guard let source = updated.firstIndex(of: section) else { return }
        let destination = source + offset
        guard updated.indices.contains(destination) else { return }
        updated.swapAt(source, destination)
        withAnimation(.snappy) {
            preferences.homeSectionOrder = updated
            save()
        }
        PlatformHaptics.impact(.light)
    }

    private func save() {
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
        Theme.currentPreferences = preferences
    }
}
