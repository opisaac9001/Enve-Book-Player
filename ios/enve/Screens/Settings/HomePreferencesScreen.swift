import SwiftUI

struct HomePreferencesScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss
    @Environment(\.profileSession) private var profileSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var preferences: UserPreferences
    @State private var dropTarget: UserPreferences.HomeSection?

    init(profileSession: ProfileSession = .owner) {
        _preferences = State(initialValue: profileSession.preferences.loadPreferences())
    }

    private var session: ProfileSession { profileSession ?? .owner }

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
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                            : AnyLayout(HStackLayout(spacing: 12))
                        layout {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.right.to.line")
                                    .foregroundStyle(hearth.ember)
                                    .frame(minWidth: 24)
                                Text("Start on")
                                    .font(.hearthBody)
                                    .foregroundStyle(hearth.text)
                                Spacer(minLength: 0)
                            }
                            Picker("Start on", selection: $preferences.preferredStartTab) {
                                ForEach(UserPreferences.PreferredStartTab.allCases) { tab in
                                    Text(tab.displayName).tag(tab)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
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
                                preferences.hiddenHomeSections = []
                                save()
                            }
                        }
                        .font(.hearthCaption.weight(.semibold))
                        .foregroundStyle(hearth.ember)
                    }

                    SourcesCard {
                        ForEach(order) { section in
                            shelfRow(section)
                        }
                    }

                    Text("Touch and hold a shelf to drag it into place. Hidden shelves stay off the Hearth. Only shelves with books appear. The hero and reading pulse stay at the top.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                    Text("Rediscover changes daily, bringing back books paused for a few weeks, older unread additions, and the next book after one you finished.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                        .accessibilityIdentifier("home-rediscover-explainer")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .hearthInteractiveBack()
        .accessibilityIdentifier("home-preferences-screen")
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

    private func shelfRow(_ section: UserPreferences.HomeSection) -> some View {
        let isHidden = preferences.hiddenHomeSections.contains(section)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal")
                    .font(.hearthUI(13, weight: .medium))
                    .foregroundStyle(hearth.textTertiary)
                    .accessibilityHidden(true)

                Image(systemName: section.glyph)
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(isHidden ? hearth.textTertiary : hearth.ember)
                    .frame(width: 24)

                Text(section.displayName)
                    .font(.hearthBody)
                    .foregroundStyle(isHidden ? hearth.textTertiary : hearth.text)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                shelfControl(
                    systemImage: isHidden ? "eye.slash" : "eye",
                    label: isHidden ? "Show \(section.displayName)" : "Hide \(section.displayName)"
                ) {
                    toggleHidden(section)
                }
                shelfControl(systemImage: "chevron.up", label: "Move \(section.displayName) up", isEnabled: order.first != section) {
                    move(section, by: -1)
                }
                shelfControl(systemImage: "chevron.down", label: "Move \(section.displayName) down", isEnabled: order.last != section) {
                    move(section, by: 1)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-shelf-\(section.rawValue)")
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(dropTarget == section ? hearth.emberSoft : .clear)
        }
        .draggable(section.rawValue) {
            Label(section.displayName, systemImage: section.glyph)
                .font(.hearthBody)
                .foregroundStyle(hearth.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(hearth.bgElevated, in: Capsule())
        }
        .dropDestination(for: String.self) { payload, _ in
            dropTarget = nil
            return moveDropped(payload, onto: section)
        } isTargeted: { isTargeted in
            if isTargeted {
                dropTarget = section
            } else if dropTarget == section {
                dropTarget = nil
            }
        }
    }

    private func shelfControl(systemImage: String, label: String, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? hearth.textSecondary : hearth.textTertiary)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    private func move(_ section: UserPreferences.HomeSection, by offset: Int) {
        var updated = order
        guard let source = updated.firstIndex(of: section) else { return }
        let destination = source + offset
        guard updated.indices.contains(destination) else { return }
        updated.swapAt(source, destination)
        applyOrder(updated)
    }

    // Any text can be dropped here, so only a single known shelf identifier reorders.
    private func moveDropped(_ payload: [String], onto target: UserPreferences.HomeSection) -> Bool {
        guard payload.count == 1,
              let dragged = UserPreferences.HomeSection(rawValue: payload[0]),
              dragged != target
        else { return false }
        var updated = order
        guard let source = updated.firstIndex(of: dragged),
              let destination = updated.firstIndex(of: target)
        else { return false }
        updated.remove(at: source)
        updated.insert(dragged, at: destination)
        applyOrder(updated)
        return true
    }

    private func applyOrder(_ updated: [UserPreferences.HomeSection]) {
        withAnimation(.snappy) {
            preferences.homeSectionOrder = updated
            save()
        }
        PlatformHaptics.impact(.light)
    }

    private func toggleHidden(_ section: UserPreferences.HomeSection) {
        withAnimation(.snappy) {
            if preferences.hiddenHomeSections.contains(section) {
                preferences.hiddenHomeSections.remove(section)
            } else {
                preferences.hiddenHomeSections.insert(section)
            }
            save()
        }
        PlatformHaptics.selection()
    }

    private func save() {
        session.preferences.savePreferences(preferences)
    }
}
