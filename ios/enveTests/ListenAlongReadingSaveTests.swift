import Foundation
import Testing
import UIKit

@testable import enve
@Suite(.serialized)
@MainActor
struct ListenAlongReadingSaveTests {
    @Test(arguments: [ReaderEngineKind.readium, .foliate])
    func readingSavesKeepTheListeningPositionWhileListenAlongHasTheAudiobook(_ engine: ReaderEngineKind) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = try ReaderOfflineOpeningTests.Fixture(mode: .reachable)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        var reader: ClassicReaderModel?
        do {
            let session = fixture.session
            var ebook = fixture.book(file: try await fixture.writeEPUB())
            var audiobook = Book(id: "listen-along-save-audio", title: "Offline EPUB", source: .local, mediaType: .audiobook)
            audiobook.duration = 600
            audiobook.currentTime = 120
            ebook.linkedAudiobookStableId = audiobook.stableId
            await session.bookStore.upsertBooks([ebook, audiobook])
            session.appState.libraryCache.ensureBookInMemory(ebook)
            session.appState.libraryCache.ensureBookInMemory(audiobook)
            await session.bookStore.upsertLink(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId, chapterOffset: 0)
            session.passageAlignment.sessionBuilderOverride = { _ in throw CancellationError() }

            let transport = ReaderLinkedReadAlongControllerTests.RecordingTransport()
            let model = ClassicReaderModel(book: ebook, readerEngineOverride: engine, providerResolver: fixture,
                profileSession: session, linkedPlayback: transport)
            reader = model
            model.startIfNeeded()
            window.frame = scene.coordinateSpace.bounds
            try await waitUntil("reader engine ready", timeout: .seconds(25)) {
                if let adapter = model.activeReaderEngineAdapter, window.rootViewController !== adapter.viewController {
                    window.rootViewController = adapter.viewController
                    window.makeKeyAndVisible()
                    window.layoutIfNeeded()
                    adapter.viewController.view.layoutIfNeeded()
                }
                switch model.state {
                case .readyEPUB, .readyFoliate: return true
                case .failed(let error): throw error
                default: return false
                }
            }
            let adapter = try #require(model.activeReaderEngineAdapter)
            try await waitUntil("Listen Along offered") { model.isLinkedReadAlongAvailable }
            transport.load(audiobook, position: 120, isPlaying: true)
            model.toggleLinkedReadAlong()
            #expect(model.isLinkedReadAlongRequested)

            let cache = session.appState.libraryCache
            func listeningTime() -> TimeInterval? { cache.bookInMemory(uniqueId: audiobook.uniqueId)?.currentTime }
            func rendered(_ href: String) async throws {
                let marker = href == "chapter-1.xhtml" ? "FIRST_CHAPTER_MARKER" : "SECOND_CHAPTER_MARKER"
                try await waitUntil("\(href) rendered") { await adapter.currentPageText()?.contains(marker) == true }
            }
            func stored(_ href: String) async throws {
                try await waitUntil("reading position \(href) stored for the book server") {
                    await session.bookStore.book(uniqueId: ebook.uniqueId)?.epubLocator?.contains(href) == true
                }
                #expect(cache.bookInMemory(uniqueId: ebook.uniqueId)?.epubLocator?.contains(href) == true)
            }
            func save(_ href: String) async throws {
                try await rendered(href)
                await model.saveProgressResolvingVisibleOverlay()
                try await stored(href)
            }

            // Browsing while narration plays, is paused, and is only named by a restored mini player.
            let browsing: [(String, Double, () -> Void)] = [
                ("chapter-1.xhtml", 0.05, { transport.load(audiobook, position: 120, isPlaying: true) }),
                ("chapter-2.xhtml", 0.9, { transport.load(audiobook, position: 120, isPlaying: false) }),
                ("chapter-1.xhtml", 0.05, { transport.load(audiobook, position: 120, isPlaying: false, isLoaded: false) }),
            ]
            for (href, fraction, player) in browsing {
                player()
                await model.seek(toProgress: fraction)
                #expect(model.linkedReadAlongStatus == .browsing)
                try await save(href)
                #expect(listeningTime() == 120)
            }

            // Following again when the reader is sent to the background: the flush pushes the reading position only.
            transport.load(audiobook, position: 120, isPlaying: true)
            await model.seek(toProgress: 0.9)
            try await rendered("chapter-2.xhtml")
            await model.saveProgressResolvingVisibleOverlay()
            model.resumeLinkedReadAlong()
            #expect(model.linkedReadAlongStatus != .browsing && model.progressPreservesListeningPosition)
            model.flushProgressToServer(reason: "background")
            try await stored("chapter-2.xhtml")
            #expect(listeningTime() == 120)
            #expect(await session.bookStore.book(uniqueId: audiobook.uniqueId)?.currentTime == 120)
            #expect(transport.commands == 0)

            // Another book in the player: the same save is ordinary linked reading again and moves the listening position.
            transport.load(Book(id: "listen-along-save-other", title: "Other", source: .local, mediaType: .audiobook), position: 3, isPlaying: true)
            await model.seek(toProgress: 0.05)
            try await save("chapter-1.xhtml")
            try await waitUntil("reading mirrored to the listening position") { listeningTime() != 120 }
            #expect(transport.commands == 0)

            let listeningBeforeClose = try #require(listeningTime())
            transport.load(audiobook, position: listeningBeforeClose, isPlaying: false)
            await model.seek(toProgress: 0.9)
            try await rendered("chapter-2.xhtml")
            #expect(model.endLinkedReadAlong())
            #expect(!model.isLinkedReadAlongRequested && model.progressPreservesListeningPosition)
            await model.saveProgressResolvingVisibleOverlay()
            model.flushProgressToServer(reason: "close")
            try await stored("chapter-2.xhtml")
            #expect(listeningTime() == listeningBeforeClose)
            #expect(await session.bookStore.book(uniqueId: audiobook.uniqueId)?.currentTime == listeningBeforeClose)
            #expect(transport.commands == 0)

            await model.retire()
            reader = nil
        } catch {
            await reader?.retire()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            await fixture.close()
            throw error
        }
        window.isHidden = true
        window.rootViewController = nil
        previousWindow?.makeKey()
        await fixture.close()
    }

    private func waitUntil(_ description: String, timeout: Duration = .seconds(8), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("\(description) not reached within \(timeout)")
        throw CancellationError()
    }
}
