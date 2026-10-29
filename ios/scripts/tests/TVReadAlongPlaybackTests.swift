import Foundation
import UIKit

struct Book {
    let stableId: String
    let lastUpdate: Date
    let epubLocator: String?
}

@main
@MainActor
final class PlaybackTestDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var started = false
    private var checks: [[String: Any]] = []
    private let player = TVStorytellerAudioPlayer()

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Audit", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = PlaybackTestSceneDelegate.self
        return configuration
    }

    func startAudit() {
        guard !started else { return }
        started = true
        Task { await audit() }
    }

    private func wait(_ seconds: Double = 0.8) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func check(_ name: String, _ passed: Bool) {
        checks.append(["name": name, "passed": passed, "clip": player.currentClipIndex, "time": player.elapsedTime, "playing": player.isPlaying, "error": player.playbackError ?? ""])
        persist()
    }

    private func persist() {
        let result: [String: Any] = ["checks": checks, "complete": false]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("results.json"), options: .atomic)
        }
    }

    private func audit() async {
        let root = Bundle.main.bundleURL
        let clips = [
            TVAudioOverlayClip(fragmentId: "s1", textHref: "chapter1.xhtml", audioSrc: "one.wav", clipBegin: 1, clipEnd: 2, skippableRole: nil),
            TVAudioOverlayClip(fragmentId: "s2", textHref: "chapter1.xhtml", audioSrc: "one.wav", clipBegin: 2.5, clipEnd: 3, skippableRole: nil),
            TVAudioOverlayClip(fragmentId: "s1", textHref: "chapter2.xhtml", audioSrc: "two.wav", clipBegin: 1, clipEnd: 2.5, skippableRole: nil),
        ]
        let book = Book(stableId: "engine-audit-" + UUID().uuidString, lastUpdate: .distantPast, epubLocator: nil)
        player.load(clips: clips, audioDir: root)
        player.restorePosition(for: book)
        await wait()
        check("loads paused at first passage", !player.isPlaying && player.currentClipIndex == 0 && abs(player.elapsedTime) < 0.05 && player.playbackError == nil)
        player.setRate(1.5)
        await wait(0.2)
        check("rate change preserves pause", !player.isPlaying && player.playbackRate == 1.5)
        player.seek(to: 0.75)
        await wait()
        check("paused exact seek", !player.isPlaying && abs(player.elapsedTime - 0.75) < 0.04)
        player.skip(by: 1)
        await wait()
        check("paused skip across audio files", !player.isPlaying && player.currentClipIndex == 2 && abs(player.elapsedTime - 1.75) < 0.04)
        player.previous()
        await wait()
        check("previous passage across files", !player.isPlaying && player.currentClipIndex == 1 && abs(player.elapsedTime - 1) < 0.04)
        player.next()
        await wait()
        check("next passage preserves pause", !player.isPlaying && player.currentClipIndex == 2 && abs(player.elapsedTime - 1.5) < 0.04)
        player.seek(to: 0.1)
        player.seek(to: 2.2)
        player.seek(to: 1.1)
        await wait(1)
        check("latest rapid seek wins", !player.isPlaying && player.currentClipIndex == 1 && abs(player.elapsedTime - 1.1) < 0.04)
        player.seek(to: 0)
        player.setRate(1)
        player.play()
        await wait(2.4)
        check("automatic cross-file transition", player.isPlaying && player.currentClipIndex == 2 && player.elapsedTime > 1.5 && player.playbackError == nil)
        player.pause()
        let savedTime = player.elapsedTime
        await wait(0.5)
        check("pause freezes narration clock", !player.isPlaying && abs(player.elapsedTime - savedTime) < 0.04)
        player.cleanup()
        player.load(clips: clips, audioDir: root)
        player.restorePosition(for: book)
        await wait()
        check("restores clip and intra-clip offset", !player.isPlaying && abs(player.elapsedTime - savedTime) < 0.05)
        player.play()
        await wait(3)
        check("completion stops and reaches duration", !player.isPlaying && abs(player.elapsedTime - player.duration) < 0.04 && player.playbackError == nil)
        player.play()
        await wait(0.5)
        check("play after completion restarts", player.isPlaying && player.elapsedTime < 1 && player.playbackError == nil)
        player.pause()
        let missing = [clips[0], TVAudioOverlayClip(fragmentId: "s2", textHref: "chapter1.xhtml", audioSrc: "missing.m4a", clipBegin: 0, clipEnd: 1, skippableRole: nil)]
        player.load(clips: missing, audioDir: root)
        await wait()
        check("missing audio fails without playback", !player.isPlaying && player.playbackError != nil)
        player.cleanup()
        let locator = "{\"href\":\"chapter2.xhtml\",\"locations\":{\"fragments\":[\"s1\"]}}"
        player.load(clips: clips, audioDir: root)
        player.restorePosition(for: Book(stableId: book.stableId, lastUpdate: Date().addingTimeInterval(1), epubLocator: locator))
        await wait()
        check("newer server locator overrides local", !player.isPlaying && player.currentClipIndex == 2 && abs(player.elapsedTime - 1.5) < 0.04)
        player.cleanup()
        player.load(clips: clips, audioDir: root)
        player.restorePosition(for: book)
        player.seek(to: 1.75)
        await wait()
        player.pause()
        player.cleanup()
        player.load(clips: clips, audioDir: root)
        player.restorePosition(for: Book(stableId: book.stableId, lastUpdate: Date().addingTimeInterval(10), epubLocator: nil))
        await wait()
        check("newer unresolved server position preserves local resume", !player.isPlaying && player.currentClipIndex == 2 && abs(player.elapsedTime - 1.75) < 0.04)
        player.play()
        await wait(0.3)
        player.pause()
        let overwritten = TVReadAlongProgressStore.shared.position(for: book.stableId)
        check("unresolved server position does not overwrite saved clip", overwritten?.href == "chapter2.xhtml")
        for (name, remote) in [
            ("malformed JSON", "not-json"),
            ("unknown chapter", "{\"href\":\"missing.xhtml\",\"locations\":{\"fragments\":[\"s1\"]}}"),
            ("unknown fragment", "{\"href\":\"chapter1.xhtml\",\"locations\":{\"fragments\":[\"missing\"]}}"),
            ("empty fragments", "{\"href\":\"chapter1.xhtml\",\"locations\":{\"fragments\":[]}}")
        ] {
            player.cleanup()
            player.load(clips: clips, audioDir: root)
            TVReadAlongProgressStore.shared.save(.init(href: "chapter2.xhtml", fragmentID: "s1", offset: 0.25, observedAt: Date()), for: book.stableId)
            player.restorePosition(for: Book(stableId: book.stableId, lastUpdate: Date().addingTimeInterval(10), epubLocator: remote))
            await wait()
            check("unusable remote preserves local: " + name, player.currentClipIndex == 2 && abs(player.elapsedTime - 1.75) < 0.04)
        }
        player.cleanup()
        player.load(clips: clips, audioDir: root)
        TVReadAlongProgressStore.shared.save(.init(href: "chapter2.xhtml", fragmentID: "s1", offset: 0.25, observedAt: Date()), for: book.stableId)
        let firstLocator = "{\"href\":\"chapter1.xhtml\",\"locations\":{\"fragments\":[\"s1\"]}}"
        player.restorePosition(for: Book(stableId: book.stableId, lastUpdate: .distantPast, epubLocator: firstLocator))
        await wait()
        check("older valid remote cannot replace newer local", player.currentClipIndex == 2 && abs(player.elapsedTime - 1.75) < 0.04)
        player.cleanup()
        player.load(clips: clips, audioDir: root)
        TVReadAlongProgressStore.shared.save(.init(href: "deleted.xhtml", fragmentID: "gone", offset: 0, observedAt: Date()), for: book.stableId)
        player.restorePosition(for: Book(stableId: book.stableId, lastUpdate: .distantPast, epubLocator: locator))
        await wait()
        check("valid remote recovers an obsolete local anchor", player.currentClipIndex == 2 && abs(player.elapsedTime - 1.5) < 0.04)
        player.cleanup()
        let result: [String: Any] = ["checks": checks, "complete": true]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("results.json"), options: .atomic)
        }
    }
}

@MainActor final class PlaybackTestSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: scene)
        window?.rootViewController = UIViewController()
        window?.makeKeyAndVisible()
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        (UIApplication.shared.delegate as? PlaybackTestDelegate)?.startAudit()
    }
}
