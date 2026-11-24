#if os(iOS)
import SwiftUI

@MainActor
@Observable
final class BookDetailSplitState {
    struct Selection {
        let book: Book
        let work: LibraryWorkRef?
    }

    private(set) var isSplit = false
    private(set) var selection: Selection?

    /// Non-nil only while a detail pane fits; a list hands it to its cells so they open the pane instead of pushing.
    var openHandler: ((Book, LibraryWorkRef?) -> Void)? {
        isSplit ? { [weak self] book, work in self?.selection = Selection(book: book, work: work) } : nil
    }

    func close() {
        selection = nil
    }

    fileprivate func update(isSplit: Bool) {
        self.isSplit = isSplit
    }
}

struct BookDetailSplit<Content: View>: View {
    let state: BookDetailSplitState
    @ViewBuilder var content: Content

    @Environment(\.hearth) private var hearth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let isSplit = HearthAdaptive.fitsDetailPane(geo.size.width)
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isSplit, let selection = state.selection {
                    Rectangle()
                        .fill(hearth.hairline)
                        .frame(width: 1)
                        .ignoresSafeArea(edges: .vertical)
                    // Its own stack, so the author, series, and edition links inside the detail stay in the pane.
                    NavigationStack {
                        if let work = selection.work {
                            WorkHubScreen(workKey: work.key, seed: selection.book, onClose: { state.close() })
                        } else {
                            BookDetailScreen(book: selection.book, onClose: { state.close() })
                        }
                    }
                    .id(selection.book.uniqueId)
                    .frame(width: HearthAdaptive.detailPaneWidth(for: geo.size.width))
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                    .accessibilityIdentifier("book-detail-pane")
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: state.selection?.book.uniqueId)
            .onChange(of: isSplit, initial: true) { _, isSplit in
                state.update(isSplit: isSplit)
            }
        }
    }
}
#endif
