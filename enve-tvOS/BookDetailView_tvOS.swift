import SwiftUI

struct BookDetailView_tvOS: View {
    let book: Book

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingCompanionPrompt = false
    @State private var isShowingTVReader = false
    @State private var isShowingReadAlong = false
    @State private var companionReceiver = CompanionReceiverService_tvOS.shared

    private var companionSessionActive: Bool {
        if case .connected = companionReceiver.state { return true }
        return false
    }

    private var hasAudio: Bool {
        book.mediaType == .audiobook || book.mediaType == .podcast
    }

    private var hasEbook: Bool {
        book.mediaType == .ebook || book.ebookFileURL != nil || book.epubLocator != nil
    }

    private var hasReadAlong: Bool {
        (book.epub3Features?.hasMediaOverlay == true || book.source == .storyteller)
            && book.ebookFileURL != nil
    }

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 80) {
                cover
                metadata
            }
            .padding(80)
        }
        .navigationTitle(book.title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { isShowingCompanionPrompt && !companionSessionActive },
                set: { isShowingCompanionPrompt = $0 }
            )
        ) {
            CompanionReadingPromptSheet_tvOS(book: book)
        }
        .fullScreenCover(isPresented: $isShowingTVReader) {
            EbookReaderView_tvOS(book: book)
        }
        .fullScreenCover(isPresented: $isShowingReadAlong) {
            StorytellerReaderView_tvOS(book: book)
        }
    }

    private var cover: some View {
        Group {
            if let url = book.coverURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    coverPlaceholder
                }
            } else {
                coverPlaceholder
            }
        }
        .frame(width: 480, height: 720)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 20)
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondary.opacity(0.3))
            .overlay(
                Image(systemName: hasAudio ? "headphones" : "book.closed")
                    .font(.system(size: 96))
                    .foregroundStyle(.secondary)
            )
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                Text(book.title)
                    .font(.system(size: 64, weight: .bold))
                    .lineLimit(3)

                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.title)
                        .foregroundStyle(.secondary)
                }

                if let series = book.series, !series.isEmpty {
                    Text(series)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }

            actionButtons

            if let description = book.description, !description.isEmpty {
                Text(description)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(8)
                    .frame(maxWidth: 800, alignment: .leading)
            }

            metadataFacts
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            if hasReadAlong {
                Button {
                    isShowingReadAlong = true
                } label: {
                    Label("Read Along on TV", systemImage: "waveform.and.person.filled")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
            } else if hasAudio {
                Button {
                    playerVM.play(book: book)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
            }

            if hasReadAlong && hasAudio {
                Button {
                    playerVM.play(book: book)
                } label: {
                    Label("Audio Only", systemImage: "play.fill")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.bordered)
            }

            if hasEbook {
                readOnTVButton
                readWithIphoneButton
            }
        }
    }

    @ViewBuilder
    private var readOnTVButton: some View {
        let button = Button {
            isShowingTVReader = true
        } label: {
            Label("Read on TV", systemImage: "text.book.closed.fill")
                .frame(minWidth: 160)
        }
        if hasAudio {
            button.buttonStyle(.bordered)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var readWithIphoneButton: some View {
        Button {
            isShowingCompanionPrompt = true
        } label: {
            Label("Read with iPhone", systemImage: "iphone.and.arrow.forward")
                .frame(minWidth: 160)
        }
        .buttonStyle(.bordered)
    }

    private var metadataFacts: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasAudio, let duration = book.duration {
                fact("Duration", formatDuration(duration))
            }
            if let narrator = book.narrator, !narrator.isEmpty {
                fact("Narrator", narrator)
            }
            if let publisher = book.publisher, !publisher.isEmpty {
                fact("Publisher", publisher)
            }
            if let language = book.language, !language.isEmpty {
                fact("Language", language)
            }
            if let publishYear = book.publishedYear {
                fact("Published", "\(publishYear)")
            }
        }
        .font(.body)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 160, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
