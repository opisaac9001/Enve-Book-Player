import SwiftUI

struct HearthTour: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Room {
        let glyph: String
        let overline: String
        let title: String
        let body: String
    }

    private let rooms: [Room] = [
        Room(
            glyph: "flame",
            overline: "The first room",
            title: "Hearth",
            body:
                "Your current book lives here, glowing in its own colors. Everything you're in the middle of waits on the shelf beside it."
        ),
        Room(
            glyph: "books.vertical",
            overline: "The second room",
            title: "Library",
            body: "Every book from every server, one set of stacks. Search first; it's faster than walking fifty thousand spines."
        ),
        Room(
            glyph: "text.quote",
            overline: "The third room",
            title: "Journal",
            body: "Nights running, hours kept, and the sentences you saved. A record of your reading life, not homework."
        ),
        Room(
            glyph: "circle.bottomhalf.filled",
            overline: "The mantel",
            title: "One bar, two jobs",
            body: "The bar below is both compass and player. When a book is active, tap it there to open the full player."
        ),
    ]

    var body: some View {
        ZStack {
            hearth.bg.ignoresSafeArea()
            EmberGlow(tint: Hearth.accent, isBreathing: true, intensity: 0.45)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { finish() }
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.textTertiary)
                        .padding(20)
                }

                TabView(selection: $page) {
                    ForEach(rooms.indices, id: \.self) { index in
                        room(rooms[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 7) {
                    ForEach(rooms.indices, id: \.self) { index in
                        Circle()
                            .fill(index == page ? hearth.ember : hearth.hairline)
                            .frame(width: 7, height: 7)
                    }
                }
                .padding(.bottom, 28)

                EmberButton(title: page == rooms.count - 1 ? "Light the fire" : "Next", systemImage: nil, tint: Hearth.accent) {
                    if page < rooms.count - 1 {
                        withAnimation(.smooth) { page += 1 }
                    } else {
                        finish()
                    }
                }
                .padding(.bottom, 44)
            }
        }
    }

    private func room(_ room: Room) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: room.glyph)
                .font(.system(size: Hearth.scaled(46), weight: .light))
                .foregroundStyle(hearth.ember)
            Overline(room.overline)
            Text(room.title)
                .font(.hearthDisplay(34))
                .foregroundStyle(hearth.text)
            Text(room.body)
                .font(.hearthUI(16))
                .foregroundStyle(hearth.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 44)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "imagine.hasSeenTour")
        dismiss()
    }
}
