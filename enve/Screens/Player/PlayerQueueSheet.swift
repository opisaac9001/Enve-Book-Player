import SwiftUI

struct PlayerQueueSheet: View {
    let tint: Color

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    private var entries: [PlaybackQueueEntry] {
        engine.playback.queue.entries
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    queueList
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !entries.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear", role: .destructive) {
                            PlatformHaptics.impact(.light)
                            engine.playback.clearQueue()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var queueList: some View {
        List {
            if let current = engine.playback.currentBook {
                Section("Now Playing") {
                    QueueBookRow(book: current, tint: tint, position: nil)
                }
            }

            Section(entries.count == 1 ? "Up Next · 1 item" : "Up Next · \(entries.count) items") {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    Button {
                        PlatformHaptics.impact(.light)
                        engine.playback.playQueued(bookID: entry.id)
                        dismiss()
                    } label: {
                        QueueBookRow(book: entry.book, tint: tint, position: index + 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            engine.playback.removeQueued(bookID: entry.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .accessibilityHint("Plays this item now")
                    .accessibilityAction(named: "Move earlier") {
                        engine.playback.moveQueued(bookID: entry.id, by: -1)
                    }
                    .accessibilityAction(named: "Move later") {
                        engine.playback.moveQueued(bookID: entry.id, by: 1)
                    }
                    .accessibilityAction(named: "Remove from Up Next") {
                        engine.playback.removeQueued(bookID: entry.id)
                    }
                }
                .onMove { offsets, destination in
                    engine.playback.moveQueued(fromOffsets: offsets, toOffset: destination)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(hearth.bgSunken)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Up Next is empty", systemImage: "text.line.first.and.arrowtriangle.forward")
        } description: {
            Text("Add books from the library, or use Play All on a series, author, or narrator page.")
        }
        .foregroundStyle(hearth.textSecondary)
    }
}

private struct QueueBookRow: View {
    let book: Book
    let tint: Color
    let position: Int?

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 13) {
            if let position {
                Text("\(position)")
                    .font(.hearthUI(12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(hearth.textTertiary)
                    .frame(width: 20, alignment: .trailing)
            }
            CoverTile(book: book, width: 42, showsProgress: false, corner: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.hearthDisplay(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if position == nil {
                Image(systemName: "waveform")
                    .font(.hearthUI(14, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}
