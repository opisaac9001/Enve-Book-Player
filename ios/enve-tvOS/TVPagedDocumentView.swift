import SwiftUI
import UIKit

struct TVPagedDocumentView: View {
    @Environment(\.hearth) private var hearth
    let book: Book
    let document: TVPagedDocument

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pageIndex: Int
    @State private var loadAttempt = 0
    @State private var loadedPage: LoadedPage?
    @State private var pageError: PageError?
    @State private var zoom: CGFloat = 1
    // Normalized pan keeps the page inside its bounds when the viewport changes.
    @State private var panAnchor: CGPoint
    @State private var surfaceSize: CGSize = .zero
    @State private var controlsVisible = false
    @FocusState private var surfaceFocused: Bool

    private static let zoomLevels: [CGFloat] = [1, 1.5, 2, 3, 4]
    private static let panFraction: CGFloat = 0.5

    private struct PageRequest: Hashable {
        let index: Int
        let attempt: Int
    }

    private struct LoadedPage {
        let index: Int
        let image: UIImage
    }

    private struct PageError {
        let index: Int
        let message: String
    }

    init(book: Book, document: TVPagedDocument) {
        self.book = book
        self.document = document
        let saved = TVPagedDocumentProgressStore.page(for: book.stableId) ?? 0
        _pageIndex = State(initialValue: min(max(saved, 0), max(document.pageCount - 1, 0)))
        _panAnchor = State(initialValue: Self.startAnchor(rightToLeft: document.rightToLeft))
    }

    var body: some View {
        ZStack {
            hearth.bgSunken.ignoresSafeArea()
            if document.pageCount == 0 {
                emptyState
            } else {
                readerBody
            }
        }
        .onPlayPauseCommand {
            if document.pageCount > 0 { toggleControls() }
        }
        .onExitCommand(perform: handleExit)
        .task(id: PageRequest(index: pageIndex, attempt: loadAttempt)) { await loadPage(pageIndex) }
        .onChange(of: pageIndex) { _, index in
            TVPagedDocumentProgressStore.save(page: index, for: book.stableId)
        }
        .sheet(isPresented: $controlsVisible, onDismiss: { surfaceFocused = true }) {
            readerControls
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: controlsVisible)
        .preferredColorScheme(.dark)
    }

    private var currentError: PageError? {
        pageError.flatMap { $0.index == pageIndex ? $0 : nil }
    }

    private var currentLayout: PageLayout? {
        guard let loadedPage, loadedPage.index == pageIndex else { return nil }
        return PageLayout(imageSize: loadedPage.image.size, container: surfaceSize, zoom: zoom)
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 80))
                .foregroundStyle(hearth.ember)
                .accessibilityHidden(true)
            Text("Can't open this book")
                .font(.title.weight(.bold))
                .foregroundStyle(hearth.text)
            Text("This document has no readable pages.")
                .font(.title3)
                .foregroundStyle(hearth.textSecondary)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 24)
        }
    }

    private var readerBody: some View {
        VStack(spacing: 24) {
            header
            if let currentError {
                failedPage(currentError)
            } else {
                readingSurface
            }
            Text(hintText)
                .font(.callout)
                .foregroundStyle(hearth.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(book.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(hearth.textSecondary)
                .lineLimit(1)
            Spacer()
            if zoom > 1 {
                Text(Double(zoom), format: .percent)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(hearth.textSecondary)
            }
            Text("Page \(pageIndex + 1) of \(document.pageCount)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(hearth.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var readingSurface: some View {
        Button(action: toggleControls) {
            GeometryReader { geometry in
                pageContent(in: geometry.size)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .onChange(of: geometry.size, initial: true) { _, size in surfaceSize = size }
            }
        }
        .buttonStyle(PageSurfaceStyle())
        .focused($surfaceFocused)
        .onAppear { surfaceFocused = true }
        .onMoveCommand(perform: handleMove)
        .onExitCommand(perform: handleExit)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: panAnchor)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: zoom)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: loadedPage?.index)
        .accessibilityLabel("Page \(pageIndex + 1) of \(document.pageCount)")
        .accessibilityValue(surfaceStatus)
        .accessibilityHint("Select to show reader controls.")
    }

    @ViewBuilder
    private func pageContent(in container: CGSize) -> some View {
        if let loadedPage, loadedPage.index == pageIndex {
            let layout = PageLayout(imageSize: loadedPage.image.size, container: container, zoom: zoom)
            Image(uiImage: loadedPage.image)
                .resizable()
                .interpolation(.high)
                .frame(width: layout.renderedSize.width, height: layout.renderedSize.height)
                .offset(x: panAnchor.x * layout.maxOffset.width, y: panAnchor.y * layout.maxOffset.height)
                .transition(reduceMotion ? .identity : .opacity)
        } else {
            ProgressView()
        }
    }

    private var surfaceStatus: String {
        if let currentError { return "Failed to load. \(currentError.message)" }
        if currentLayout == nil { return "Loading" }
        return zoom > 1 ? "Zoomed to \(Double(zoom).formatted(.percent))" : "Fit to screen"
    }

    private func failedPage(_ error: PageError) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 64))
                .foregroundStyle(hearth.ember)
            Text("Can't show page \(error.index + 1)")
                .font(.title2.weight(.semibold))
                .foregroundStyle(hearth.text)
            Text(error.message)
                .font(.callout)
                .foregroundStyle(hearth.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 800)
            HStack(spacing: 28) {
                Button("Retry") { loadAttempt += 1 }
                Button("Next Page") { turnPage(forward: true) }
                Button("Done") { dismiss() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hintText: String {
        var parts = ["Select for controls", rightToLeft ? "◂ ▸ Turn pages (right to left)" : "◂ ▸ Turn pages"]
        if zoom > 1 { parts.append("▴ ▾ Scroll") }
        return parts.joined(separator: "  ·  ")
    }

    private var readerControls: some View {
        NavigationStack {
            List {
                Section("Zoom · \(Double(zoom).formatted(.percent))") {
                    Button("Zoom In", systemImage: "plus.magnifyingglass") { zoomIn() }
                    Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoomOut() }
                    Button("Fit Page", systemImage: "arrow.down.right.and.arrow.up.left") {
                        fitPage()
                        controlsVisible = false
                    }
                }
                Section("Page \(pageIndex + 1) of \(document.pageCount)") {
                    Button("Previous Page", systemImage: "backward") {
                        turnPage(forward: false)
                        controlsVisible = false
                    }
                    Button("Next Page", systemImage: "forward") {
                        turnPage(forward: true)
                        controlsVisible = false
                    }
                }
                Button("Back to Reading") { controlsVisible = false }
            }
            .hearthCanvas()
            .navigationTitle("Reader Controls")
        }
        .onExitCommand { controlsVisible = false }
    }

    private var rightToLeft: Bool { document.rightToLeft }

    private static func startAnchor(rightToLeft: Bool) -> CGPoint {
        CGPoint(x: rightToLeft ? -1 : 1, y: 1)
    }

    private static func nudged(_ value: CGFloat, by distance: CGFloat, within limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return value }
        return min(1, max(-1, value + distance / limit))
    }

    private func handleMove(_ direction: MoveCommandDirection) {
        let maxOffset = currentLayout?.maxOffset ?? .zero
        let verticalStep = surfaceSize.height * Self.panFraction
        let horizontalStep = surfaceSize.width * Self.panFraction
        switch direction {
        case .up:
            panAnchor.y = Self.nudged(panAnchor.y, by: verticalStep, within: maxOffset.height)
        case .down:
            panAnchor.y = Self.nudged(panAnchor.y, by: -verticalStep, within: maxOffset.height)
        case .left:
            let next = Self.nudged(panAnchor.x, by: horizontalStep, within: maxOffset.width)
            if next != panAnchor.x { panAnchor.x = next } else { turnPage(forward: rightToLeft) }
        case .right:
            let next = Self.nudged(panAnchor.x, by: -horizontalStep, within: maxOffset.width)
            if next != panAnchor.x { panAnchor.x = next } else { turnPage(forward: !rightToLeft) }
        @unknown default:
            break
        }
    }

    private func turnPage(forward: Bool) {
        let target = min(max(pageIndex + (forward ? 1 : -1), 0), document.pageCount - 1)
        guard target != pageIndex else { return }
        pageIndex = target
        panAnchor = Self.startAnchor(rightToLeft: rightToLeft)
    }

    private func zoomIn() {
        if let next = Self.zoomLevels.first(where: { $0 > zoom }) { zoom = next }
    }

    private func zoomOut() {
        if let previous = Self.zoomLevels.last(where: { $0 < zoom }) { zoom = previous }
    }

    private func fitPage() {
        zoom = 1
        panAnchor = Self.startAnchor(rightToLeft: rightToLeft)
    }

    private func toggleControls() {
        controlsVisible.toggle()
    }

    private func handleExit() {
        if controlsVisible {
            controlsVisible = false
        } else {
            dismiss()
        }
    }

    private func loadPage(_ index: Int) async {
        loadedPage = nil
        pageError = nil
        do {
            let image = try await document.image(at: index)
            guard !Task.isCancelled, index == pageIndex else { return }
            loadedPage = LoadedPage(index: index, image: image)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), index == pageIndex else { return }
            pageError = PageError(index: index, message: error.localizedDescription)
        }
    }
}

private struct PageLayout {
    let renderedSize: CGSize
    let maxOffset: CGSize

    init(imageSize: CGSize, container: CGSize, zoom: CGFloat) {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            renderedSize = .zero
            maxOffset = .zero
            return
        }
        let fit = min(container.width / imageSize.width, container.height / imageSize.height) * zoom
        renderedSize = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
        maxOffset = CGSize(
            width: max(0, (renderedSize.width - container.width) / 2),
            height: max(0, (renderedSize.height - container.height) / 2)
        )
    }
}

// The surface owns focus without the system lift so the publication page is never scaled or distorted.
private struct PageSurfaceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

private enum TVPagedDocumentProgressStore {
    private static let keyPrefix = "enveTV.pagedDocument.page."

    static func page(for bookID: String) -> Int? {
        UserDefaults.standard.object(forKey: keyPrefix + bookID) as? Int
    }

    static func save(page: Int, for bookID: String) {
        UserDefaults.standard.set(page, forKey: keyPrefix + bookID)
    }
}
