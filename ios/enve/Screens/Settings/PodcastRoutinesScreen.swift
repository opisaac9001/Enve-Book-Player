#if os(iOS)
import SwiftUI

struct PodcastRoutinesScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    @State private var editingRoutineID: UUID?

    private var store: PodcastRoutineStore { engine.podcasts.routines }
    private var runner: PodcastRoutineRunner { engine.podcasts.routineRunner }

    var body: some View {
        SettingsScaffold(
            overline: "Podcasts",
            title: "Routines",
            subtitle: "Saved lineups of your shows. Episodes are chosen fresh each time you press Play, and Up Next only changes once something is ready."
        ) {
            PodcastRoutineRunStatus()

            if engine.podcasts.subscriptions.isEmpty {
                SourcesCard {
                    HearthEmpty(
                        glyph: "antenna.radiowaves.left.and.right",
                        title: "No shows yet",
                        line: "Routines are built from the podcast feeds you subscribe to in Enve."
                    )
                }
            } else if store.routines.isEmpty {
                SourcesCard {
                    HearthEmpty(
                        glyph: "list.bullet.rectangle",
                        title: "No routines yet",
                        line: "Make one for the morning walk or a long drive."
                    )
                }
            } else {
                SourcesCard {
                    ForEach(Array(store.routines.enumerated()), id: \.element.id) { index, routine in
                        if index > 0 { Divider().overlay(hearth.hairline) }
                        row(routine, index: index)
                    }
                }
            }

            EmberButton(title: "New routine", systemImage: "plus") { create() }
                .disabled(!store.canCreate || engine.podcasts.subscriptions.isEmpty)
                .opacity(store.canCreate && !engine.podcasts.subscriptions.isEmpty ? 1 : 0.5)
                .accessibilityIdentifier("podcast-routine-new")
        }
        .accessibilityIdentifier("podcast-routines-screen")
        .navigationDestination(item: $editingRoutineID) { id in
            PodcastRoutineEditorScreen(routineID: id)
        }
    }

    private func row(_ routine: PodcastRoutine, index: Int) -> some View {
        HStack(spacing: 12) {
            Button { editingRoutineID = routine.id } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(routine.name)
                            .font(.hearthBody.weight(.medium))
                            .foregroundStyle(hearth.text)
                        Text(PodcastRoutineFormat.summary(routine))
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.hearthUI(12, weight: .semibold))
                        .foregroundStyle(hearth.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(routine.name)")
            .accessibilityValue(PodcastRoutineFormat.summary(routine))
            .accessibilityIdentifier("podcast-routine-row-\(index)")
            .accessibilityAction(named: "Move up") { store.move(id: routine.id, by: -1) }
            .accessibilityAction(named: "Move down") { store.move(id: routine.id, by: 1) }
            .contextMenu {
                Button("Move up", systemImage: "arrow.up") { store.move(id: routine.id, by: -1) }
                    .disabled(index == 0)
                Button("Move down", systemImage: "arrow.down") { store.move(id: routine.id, by: 1) }
                    .disabled(index == store.routines.count - 1)
            }

            PodcastRoutinePlayButton(routine: routine)
                .accessibilityIdentifier("podcast-routine-play-\(index)")
        }
    }

    private func create() {
        let subscriptions = engine.podcasts.subscriptions
        let firstRule = subscriptions.first.map { PodcastRoutineRule(feedURL: $0.feedURL, showTitle: $0.title) }
        guard let routine = store.create(named: "Routine \(store.routines.count + 1)", rules: firstRule.map { [$0] } ?? []) else { return }
        editingRoutineID = routine.id
    }
}

struct PodcastRoutineEditorScreen: View {
    let routineID: UUID

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var draft: PodcastRoutine?
    @State private var confirmingDelete = false

    private var store: PodcastRoutineStore { engine.podcasts.routines }

    var body: some View {
        SettingsScaffold(overline: "Routine", title: draft?.name ?? "Routine") {
            if let routine = Binding($draft) {
                editor(routine)
            }
        }
        .accessibilityIdentifier("podcast-routine-editor")
        .onAppear {
            if draft == nil { draft = store.routine(id: routineID) }
        }
        .onChange(of: draft) { _, routine in
            if let routine { store.save(routine) }
        }
        .confirmationDialog("Delete this routine?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete routine", role: .destructive) {
                store.delete(id: routineID)
                draft = nil
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your subscriptions, downloads and listening progress aren't affected.")
        }
    }

    @ViewBuilder
    private func editor(_ routine: Binding<PodcastRoutine>) -> some View {
        SourcesCard {
            SourcesField(label: "Name", text: routine.name, placeholder: "Morning walk")
                .accessibilityIdentifier("podcast-routine-name")
        }

        PodcastRoutineRunStatus()

        Overline("Shows, in play order")
            .accessibilityAddTraits(.isHeader)
        if routine.wrappedValue.rules.isEmpty {
            Text("Add a show to choose which episodes this routine plays.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
        ForEach(routine.rules) { $rule in
            ruleCard($rule, in: routine)
        }

        HStack(spacing: 10) {
            QuietButton(title: "Add a show", systemImage: "plus") { addRule(to: routine) }
                .disabled(routine.wrappedValue.rules.count >= PodcastRoutineStore.maximumRules || engine.podcasts.subscriptions.isEmpty)
                .accessibilityIdentifier("podcast-routine-add-rule")
            PodcastRoutinePlayButton(routine: routine.wrappedValue, showsTitle: true)
                .accessibilityIdentifier("podcast-routine-play")
        }

        QuietButton(title: "Delete routine", systemImage: "trash") { confirmingDelete = true }
            .padding(.top, 12)
            .accessibilityIdentifier("podcast-routine-delete")
    }

    private func ruleCard(_ rule: Binding<PodcastRoutineRule>, in routine: Binding<PodcastRoutine>) -> some View {
        let value = rule.wrappedValue
        let index = routine.wrappedValue.rules.firstIndex { $0.id == value.id } ?? 0
        let isSubscribed = engine.podcasts.isSubscribed(feedURL: value.feedURL)
        return SourcesCard {
            HStack(alignment: .top, spacing: 8) {
                Menu {
                    ForEach(engine.podcasts.subscriptions) { subscription in
                        Button(subscription.title) {
                            rule.wrappedValue.feedURL = subscription.feedURL
                            rule.wrappedValue.showTitle = subscription.title
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(value.showTitle)
                            .font(.hearthBody.weight(.semibold))
                            .foregroundStyle(hearth.text)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.hearthUI(10, weight: .semibold))
                            .foregroundStyle(hearth.ember)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Show")
                .accessibilityValue(value.showTitle)
                .accessibilityHint("Choose which subscribed show this step uses")
                Spacer(minLength: 4)
                GlyphButton(systemImage: "chevron.up", size: 34, glyphSize: 12, label: "Move \(value.showTitle) earlier") {
                    move(value.id, by: -1, in: routine)
                }
                .disabled(index == 0)
                GlyphButton(systemImage: "chevron.down", size: 34, glyphSize: 12, label: "Move \(value.showTitle) later") {
                    move(value.id, by: 1, in: routine)
                }
                .disabled(index == routine.wrappedValue.rules.count - 1)
                GlyphButton(systemImage: "trash", size: 34, glyphSize: 12, label: "Remove \(value.showTitle)") {
                    routine.wrappedValue.rules.removeAll { $0.id == value.id }
                }
            }

            if !isSubscribed {
                Text("You're no longer subscribed to this show, so it will be skipped.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                HearthChip(title: "Newest unplayed", isSelected: value.pick == .newestUnplayed) {
                    rule.wrappedValue.pick = .newestUnplayed
                }
                HearthChip(title: "Next in order", isSelected: value.pick != .newestUnplayed) {
                    if value.pick == .newestUnplayed { rule.wrappedValue.pick = .nextUnplayed(1) }
                }
            }

            if case .nextUnplayed(let count) = value.pick {
                Stepper(value: Binding(get: { count }, set: { rule.wrappedValue.pick = .nextUnplayed($0) }), in: PodcastRoutineRule.Pick.countRange) {
                    Text(count == 1 ? "Next episode" : "Next \(count) episodes")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                }
                .accessibilityIdentifier("podcast-routine-rule-count-\(index)")
            }

            Text(value.pick == .newestUnplayed
                ? "The latest episode you haven't finished, resuming where you left off."
                : "Continues in order after the last episode you played, without skipping ahead.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("podcast-routine-rule-\(index)")
    }

    private func addRule(to routine: Binding<PodcastRoutine>) {
        let used = Set(routine.wrappedValue.rules.map { PodcastFeedURL.key($0.feedURL) })
        let subscriptions = engine.podcasts.subscriptions
        guard let subscription = subscriptions.first(where: { !used.contains(PodcastFeedURL.key($0.feedURL)) }) ?? subscriptions.first else { return }
        routine.wrappedValue.rules.append(PodcastRoutineRule(feedURL: subscription.feedURL, showTitle: subscription.title))
    }

    private func move(_ id: UUID, by delta: Int, in routine: Binding<PodcastRoutine>) {
        var rules = routine.wrappedValue.rules
        guard let source = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(source + delta) else { return }
        rules.swapAt(source, source + delta)
        routine.wrappedValue.rules = rules
    }
}

struct PodcastRoutinePlayButton: View {
    let routine: PodcastRoutine
    var showsTitle = false

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    var body: some View {
        let runner = engine.podcasts.routineRunner
        let isRunning = runner.runningRoutineID == routine.id
        Group {
            if isRunning {
                ProgressView()
                    .tint(hearth.ember)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Choosing episodes for \(routine.name)")
            } else if showsTitle {
                EmberButton(title: "Play", systemImage: "play.fill") { runner.start(routine) }
                    .accessibilityLabel("Play \(routine.name)")
            } else {
                GlyphButton(systemImage: "play.fill", glyphSize: 15, prominent: true, label: "Play \(routine.name)") {
                    runner.start(routine)
                }
            }
        }
        .disabled(routine.rules.isEmpty)
        .opacity(routine.rules.isEmpty ? 0.5 : 1)
    }
}

struct PodcastRoutineRunStatus: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    var body: some View {
        let runner = engine.podcasts.routineRunner
        if let id = runner.runningRoutineID {
            SourcesCard {
                HStack(spacing: 12) {
                    ProgressView().tint(hearth.ember)
                    Text("Choosing episodes for \(engine.podcasts.routines.routine(id: id)?.name ?? "your routine")…")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                QuietButton(title: "Cancel", systemImage: "xmark") { runner.cancel() }
                    .accessibilityIdentifier("podcast-routine-cancel")
            }
            .accessibilityIdentifier("podcast-routine-run-status")
        } else if let run = runner.lastRun {
            SourcesCard {
                Label(
                    run.didPlay
                        ? "Playing \(run.queuedCount == 1 ? "1 episode" : "\(run.queuedCount) episodes") from \(run.routineName)"
                        : "Nothing to play from \(run.routineName)",
                    systemImage: run.didPlay ? "play.circle" : "exclamationmark.circle"
                )
                .font(.hearthBody.weight(.semibold))
                .foregroundStyle(run.didPlay ? hearth.text : hearth.statusWarn)
                .fixedSize(horizontal: false, vertical: true)
                if !run.didPlay {
                    Text("Up Next wasn't changed.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                if run.wasOffline {
                    Text("You're offline, so only downloaded episodes were considered.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(run.explanations) { outcome in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.showTitle)
                            .font(.hearthCaption.weight(.semibold))
                            .foregroundStyle(hearth.text)
                        Text(outcome.note ?? "")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                QuietButton(title: "Dismiss") { runner.dismissResult() }
                    .accessibilityIdentifier("podcast-routine-dismiss-result")
            }
            .accessibilityIdentifier("podcast-routine-run-status")
        }
    }
}

enum PodcastRoutineFormat {
    static func summary(_ routine: PodcastRoutine) -> String {
        guard !routine.rules.isEmpty else { return "No shows yet" }
        let shows = Set(routine.rules.map { PodcastFeedURL.key($0.feedURL) }).count
        let episodes = routine.rules.reduce(0) { $0 + $1.pick.maximumEpisodes }
        let showText = shows == 1 ? "1 show" : "\(shows) shows"
        let episodeText = episodes == 1 ? "1 episode" : "up to \(episodes) episodes"
        return "\(showText) · \(episodeText)"
    }
}
#endif
