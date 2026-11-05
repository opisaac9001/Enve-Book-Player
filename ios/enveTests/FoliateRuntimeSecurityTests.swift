import Foundation
import Testing

@testable import enve

struct FoliateRuntimeSecurityTests {
    @Test func networkBlockerUsesWebKitCompatibleRulesForEveryExternalScheme() throws {
        let data = try #require(FoliateRuntimeSupport.networkBlockerSource.data(using: .utf8))
        let rules = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let filters = try rules.map { rule in
            let trigger = try #require(rule["trigger"] as? [String: Any])
            #expect(trigger["url-filter-is-case-sensitive"] as? Bool == false)
            let action = try #require(rule["action"] as? [String: Any])
            #expect(action["type"] as? String == "block")
            return try #require(trigger["url-filter"] as? String)
        }

        #expect(Set(filters) == ["^http:", "^https:", "^ws:", "^wss:", "^ftp:"])
        #expect(filters.allSatisfy { !$0.contains("|") })
    }

    @Test func servesOnlyThePackagedRuntimeAllowlist() {
        for path in [
            "/index.html",
            "/adapter.js",
            "/reader.css",
            "/session.json",
            "/book/current.epub",
            "/foliate/view.js",
            "/foliate/epub.js",
            "/foliate/epubcfi.js",
            "/foliate/fixed-layout.js",
            "/foliate/footnotes.js",
            "/foliate/overlayer.js",
            "/foliate/paginator.js",
            "/foliate/progress.js",
            "/foliate/search.js",
            "/foliate/text-walker.js",
            "/foliate/tts.js",
            "/foliate/vendor/zip.js",
            "/foliate/vendor/fflate.js",
            "/book/current.azw3",
        ] {
            #expect(FoliateRuntimeSupport.isAllowedRuntimePath(path))
        }
    }

    @Test func rejectsTraversalAndUnlistedScripts() {
        for path in [
            "/foliate/../adapter.js",
            "/foliate/%2e%2e/adapter.js",
            "/foliate/tests/tests.js",
            "/foliate/reader.js",
            "/licenses/foliate-LICENSE.txt",
            "/book/other.epub",
            "/session.json/extra",
        ] {
            #expect(!FoliateRuntimeSupport.isAllowedRuntimePath(path))
        }
    }

    @Test func paragraphIndentRemainsInheritedByParagraphContent() throws {
        let runtimeRoot = try #require(FoliateRuntimeSupport.resourceRoot)
        let source = try String(
            contentsOf: runtimeRoot.appendingPathComponent("adapter.js"),
            encoding: .utf8
        )

        #expect(source.contains("text-indent: ${Math.max(0, next.paragraphIndent)}em !important;"))
        #expect(!source.contains("p * {\\n            text-indent: 0 !important;"))
    }

    @Test func verticalMarginsUseTheFoliatePageFrame() throws {
        let runtimeRoot = try #require(FoliateRuntimeSupport.resourceRoot)
        let source = try String(
            contentsOf: runtimeRoot.appendingPathComponent("adapter.js"),
            encoding: .utf8
        )

        #expect(source.contains("const verticalMargin = Math.max(0, (next.topMargins + next.bottomMargins) / 2) * 16"))
        #expect(source.contains("renderer.setAttribute('margin', `${verticalMargin}px`)"))
        #expect(source.contains("renderer.setAttribute('max-block-size', `calc(100% - ${verticalMargin * 2}px)`)"))
        #expect(!source.contains("padding-block-start: ${Math.max(0, next.topMargins)}rem"))
        #expect(!source.contains("padding-block-end: ${Math.max(0, next.bottomMargins)}rem"))
    }

    @Test func ttsHighlightAndPageFollowAreIndependent() throws {
        let runtimeRoot = try #require(FoliateRuntimeSupport.resourceRoot)
        let source = try String(
            contentsOf: runtimeRoot.appendingPathComponent("adapter.js"),
            encoding: .utf8
        )

        #expect(source.contains("if (!content?.doc && navigateToResource)"))
        #expect(source.contains("isCurrent, draw = Overlayer.highlight) => {"))
        #expect(source.contains("overlayer.add(key, resolved.range, draw, { color })"))
        #expect(source.contains("ttsAnnotationKey, locatorJSON, ttsHighlightColor, false"))
        #expect(source.contains("const ttsAnnotationKey = 'enve-tts-current'"))
        #expect(source.contains("const followTTSLocator = async (locatorJSON, strictQuote = false) =>"))
        #expect(source.contains("case 'ttsStart':"))
        #expect(source.contains("case 'ttsAt':"))
        #expect(source.contains("new Intl.Segmenter(language, { granularity: 'sentence' })"))
        #expect(source.contains("locator.cfi = null"))
        #expect(source.contains("locator.domRange = null"))
        #expect(source.contains("if (!isVisible && !lastSelection) await view.renderer.scrollToAnchor?.(range)"))
        let highlight = try #require(source.range(of: "const applyTTSLocator"))
        let follow = try #require(source.range(of: "const followTTSLocator"))
        let highlightBody = source[highlight.lowerBound..<follow.lowerBound]
        #expect(!highlightBody.contains("view.goTo"))
        #expect(!highlightBody.contains("scrollToAnchor"))
    }

    @Test func narrationHighlightSurvivesSectionLoadsAndSavedHighlightHits() throws {
        let runtimeRoot = try #require(FoliateRuntimeSupport.resourceRoot)
        let source = try String(
            contentsOf: runtimeRoot.appendingPathComponent("adapter.js"),
            encoding: .utf8
        )

        #expect(source.contains("Promise.resolve().then(drawTTSHighlight)"))
        #expect(source.contains("overlayer.hitTest = hitTestSkippingNarration"))
        #expect(source.contains("if (lastSelection) return"))
    }

    @Test func readAlongHighlightIsSeparateFromNarrationAndNeverUsesAnUnanchoredQuote() throws {
        let runtimeRoot = try #require(FoliateRuntimeSupport.resourceRoot)
        let source = try String(
            contentsOf: runtimeRoot.appendingPathComponent("adapter.js"),
            encoding: .utf8
        )

        #expect(source.contains("const readAlongAnnotationKey = 'enve-readalong-current'"))
        #expect(source.contains("case 'readAlong':"))
        #expect(source.contains("case 'readAlongFollow':"))
        #expect(source.contains("await followTTSLocator(payload.locatorJSON, true)"))
        #expect(source.contains("Promise.resolve().then(drawReadAlongHighlight)"))
        #expect(source.contains("strictQuote && (locator.prefix || locator.suffix)"))
        #expect(source.contains("readAlongAnnotationKey, locatorJSON, color, true"))
        let readAlong = try #require(source.range(of: "const applyReadAlongLocator"))
        let next = try #require(source.range(of: "const textPointAtOffset"))
        let readAlongBody = source[readAlong.lowerBound..<next.lowerBound]
        #expect(!readAlongBody.contains("ttsAnnotationKey"))
        #expect(!readAlongBody.contains("view.goTo"))
    }

    @Test func readAlongWordIsAnUnderlineLayerThatNeverNavigates() throws {
        let runtimeRoot = try #require(FoliateRuntimeSupport.resourceRoot)
        let source = try String(contentsOf: runtimeRoot.appendingPathComponent("adapter.js"), encoding: .utf8)

        #expect(source.contains("const readAlongWordAnnotationKey = 'enve-readalong-word'"))
        #expect(source.contains("case 'readAlongWord':"))
        #expect(source.contains("Overlayer.underline"))
        #expect(source.contains(".then(drawReadAlongWordHighlight)"))
        let word = try #require(source.range(of: "const applyReadAlongWordLocator"))
        let next = try #require(source.range(of: "const textPointAtOffset"))
        let body = source[word.lowerBound..<next.lowerBound]
        #expect(body.contains("readAlongWordAnnotationKey"))
        #expect(!body.contains("view.goTo"))
        #expect(!body.contains("followTTSLocator"))
    }

    @Test func readerFontUsesPrivateFamilyAndReachesInlinePublisherRules() throws {
        let runtimeRoot = try #require(FoliateRuntimeSupport.resourceRoot)
        let source = try String(
            contentsOf: runtimeRoot.appendingPathComponent("adapter.js"),
            encoding: .utf8
        )

        #expect(source.contains("return '\"Enve OpenDyslexic\", sans-serif'"))
        #expect(source.contains("body *:not(code, kbd, samp, var, pre, pre *, code *)"))
    }
}
