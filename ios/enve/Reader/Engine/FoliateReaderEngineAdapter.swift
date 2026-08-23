import CoreFoundation
import Foundation
import Logging
@preconcurrency import ReadiumShared
import UIKit
@preconcurrency import WebKit

enum FoliateRuntimeSupport {
    static let scheme = "enve-foliate"
    static let host = "runtime"
    static let requiredCapabilities = Set(ReaderEngineCapability.allCases)
    static let networkBlockerSource = """
        [
            {
                "trigger": {
                    "url-filter": "^http:",
                    "url-filter-is-case-sensitive": false
                },
                "action": { "type": "block" }
            },
            {
                "trigger": {
                    "url-filter": "^https:",
                    "url-filter-is-case-sensitive": false
                },
                "action": { "type": "block" }
            },
            {
                "trigger": {
                    "url-filter": "^ws:",
                    "url-filter-is-case-sensitive": false
                },
                "action": { "type": "block" }
            },
            {
                "trigger": {
                    "url-filter": "^wss:",
                    "url-filter-is-case-sensitive": false
                },
                "action": { "type": "block" }
            },
            {
                "trigger": {
                    "url-filter": "^ftp:",
                    "url-filter-is-case-sensitive": false
                },
                "action": { "type": "block" }
            }
        ]
        """

    static var resourceRoot: URL? {
        let bundleURL =
            Bundle.main.url(forResource: "FoliateRuntime", withExtension: "bundle")
            ?? Bundle.main.resourceURL?.appendingPathComponent("FoliateRuntime.bundle")
        guard let bundleURL,
            let bundle = Bundle(url: bundleURL),
            let root = bundle.resourceURL
        else {
            return nil
        }
        return root
    }

    static var isPackaged: Bool {
        guard let root = resourceRoot else { return false }
        return [
            "index.html",
            "adapter.js",
            "reader.css",
            "foliate/view.js",
            "foliate/epub.js",
            "foliate/fb2.js",
            "foliate/mobi.js",
            "foliate/epubcfi.js",
            "foliate/fixed-layout.js",
            "foliate/footnotes.js",
            "foliate/overlayer.js",
            "foliate/paginator.js",
            "foliate/progress.js",
            "foliate/vendor/zip.js",
            "foliate/search.js",
            "foliate/text-walker.js",
            "foliate/tts.js",
        ].allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    static let streamedResourcePrefix = "/book/resource/"

    static func isAllowedRuntimePath(_ path: String) -> Bool {
        if path.hasPrefix(streamedResourcePrefix), path.count > streamedResourcePrefix.count {
            return true
        }
        switch path {
        case "/index.html",
            "/adapter.js",
            "/reader.css",
            "/session.json",
            "/book/current.epub",
            "/book/current.fb2",
            "/foliate/view.js",
            "/foliate/epub.js",
            "/foliate/fb2.js",
            "/foliate/mobi.js",
            "/foliate/epubcfi.js",
            "/foliate/fixed-layout.js",
            "/foliate/footnotes.js",
            "/foliate/overlayer.js",
            "/foliate/paginator.js",
            "/foliate/progress.js",
            "/foliate/search.js",
            "/foliate/text-walker.js",
            "/foliate/tts.js",
            "/foliate/vendor/zip.js":
            return true
        default:
            return false
        }
    }
}

enum FoliateBookSource {
    case file(URL, fileExtension: String)
    case streamed(GrimmoryEpubStreamingSession)
}

enum FoliateReaderError: LocalizedError {
    case runtimeUnavailable
    case networkBlockerUnavailable
    case startupTimedOut
    case invalidRuntimeMessage
    case missingCapabilities
    case unsupportedAnnotation
    case unsupportedCustomFont
    case commandFailed
    case commandTimedOut

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            "Foliate runtime resources are unavailable."
        case .networkBlockerUnavailable:
            "Foliate network isolation could not be configured."
        case .startupTimedOut:
            "Foliate did not finish loading the book."
        case .invalidRuntimeMessage:
            "Foliate sent an invalid reader event."
        case .missingCapabilities:
            "Foliate is missing a reader capability required by Enve."
        case .unsupportedAnnotation:
            "An existing annotation cannot be represented safely in Foliate."
        case .unsupportedCustomFont:
            "The selected reader font is unavailable to Foliate."
        case .commandFailed:
            "Foliate could not complete a reader action."
        case .commandTimedOut:
            "Foliate did not complete the reader action in time."
        }
    }
}

private struct FoliateReaderPreferences {
    let theme: String
    let fontFamily: String
    let customFontFamily: String?
    let customFontCSS: String?
    let columns: String
    let fontSize: Double
    let lineHeight: Double
    let pageMargins: Double
    let topMargins: Double
    let bottomMargins: Double
    let paragraphSpacing: Double
    let paragraphIndent: Double
    let scroll: Bool
    let publisherStyles: Bool
    let justified: Bool
    let wordSpacing: Double
    let letterSpacing: Double
    let bionic: Bool
    let direction: String
    let verticalWriting: Bool?

    init(appearance: ClassicReaderAppearance) throws {
        theme = appearance.theme.rawValue
        fontFamily = appearance.fontFamily.rawValue
        columns = appearance.columnMode.rawValue
        fontSize = appearance.fontSize
        lineHeight = appearance.lineHeight
        pageMargins = appearance.pageMargins
        topMargins = appearance.topMargins
        bottomMargins = appearance.bottomMargins
        paragraphSpacing = appearance.paragraphSpacing
        paragraphIndent = appearance.paragraphIndent
        scroll = appearance.scrollEnabled
        publisherStyles = appearance.theme == .eink ? false : appearance.publisherStyles
        justified = appearance.justifiedText
        wordSpacing = appearance.wordSpacing
        letterSpacing = appearance.letterSpacing
        bionic = appearance.bionicReading
        direction = appearance.writingDirection.rawValue
        verticalWriting = appearance.verticalWriting

        if appearance.usesCustomFont {
            guard let familyName = appearance.customFontFamilyName,
                !familyName.isEmpty,
                let family = ReaderFontLibrary.shared.fontFamily(named: familyName),
                !family.files.isEmpty
            else {
                throw FoliateReaderError.unsupportedCustomFont
            }
            let rules = try family.files.map { file -> String in
                let url = URL(fileURLWithPath: file.filePath)
                guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                    throw FoliateReaderError.unsupportedCustomFont
                }
                let mime = url.pathExtension.lowercased() == "otf" ? "font/otf" : "font/ttf"
                let format = mime == "font/otf" ? "opentype" : "truetype"
                let style = file.style == .italic ? "italic" : "normal"
                let weight: String
                switch file.weightKind {
                case .standardNormal:
                    weight = "400"
                case .standardBold:
                    weight = "700"
                case .variable(let range):
                    weight = "\(range.lowerBound) \(range.upperBound)"
                }
                let escapedFamily =
                    familyName
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                return """
                    @font-face {
                        font-family: '\(escapedFamily)';
                        src: url('data:\(mime);base64,\(data.base64EncodedString())') format('\(format)');
                        font-style: \(style);
                        font-weight: \(weight);
                        font-display: block;
                    }
                    """
            }
            customFontFamily = familyName
            customFontCSS = rules.joined(separator: "\n")
        } else {
            customFontFamily = nil
            customFontCSS = nil
        }
    }

    var jsonObject: [String: Any] {
        [
            "theme": theme,
            "fontFamily": fontFamily,
            "customFontFamily": customFontFamily ?? NSNull(),
            "customFontCSS": customFontCSS ?? NSNull(),
            "columns": columns,
            "fontSize": fontSize,
            "lineHeight": lineHeight,
            "pageMargins": pageMargins,
            "topMargins": topMargins,
            "bottomMargins": bottomMargins,
            "paragraphSpacing": paragraphSpacing,
            "paragraphIndent": paragraphIndent,
            "scroll": scroll,
            "publisherStyles": publisherStyles,
            "justified": justified,
            "wordSpacing": wordSpacing,
            "letterSpacing": letterSpacing,
            "bionic": bionic,
            "direction": direction,
            "verticalWriting": verticalWriting ?? NSNull(),
        ]
    }
}

private struct FoliateAnnotationPayload {
    let id: String
    let cfi: String
    let color: String
    let style: String
    let hasNote: Bool

    var jsonObject: [String: Any] {
        [
            "id": id,
            "cfi": cfi,
            "color": color,
            "style": style,
            "hasNote": hasNote,
        ]
    }

    static func make(from annotation: ReaderAnnotation) throws -> FoliateAnnotationPayload? {
        guard !annotation.isRemotePlaceholder else { return nil }
        guard
            let cfi = EpubLocationBridge.canonicalFullEPUBCFI(
                EpubLocationBridge.epubCFI(from: annotation.locator)
            )
        else {
            throw FoliateReaderError.unsupportedAnnotation
        }
        return FoliateAnnotationPayload(
            id: annotation.id,
            cfi: cfi,
            color: annotation.colorHex,
            style: annotation.style.rawValue,
            hasNote: annotation.note?.isEmpty == false
        )
    }
}

private final class FoliateURLSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let runtimeRoot: URL
    private let bookData: Data?
    private let bookExtension: String
    private let streamingSession: GrimmoryEpubStreamingSession?
    private let sessionData: Data
    private let handlerName: String
    private let capability: String
    private var liveResourceTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(
        runtimeRoot: URL,
        source: FoliateBookSource,
        sessionData: Data,
        handlerName: String,
        capability: String
    ) throws {
        self.runtimeRoot = runtimeRoot
        switch source {
        case .file(let bookURL, let fileExtension):
            bookData = try Data(contentsOf: bookURL, options: [.mappedIfSafe])
            bookExtension = fileExtension.lowercased() == EbookFormat.fb2.rawValue
                ? EbookFormat.fb2.rawValue
                : EbookFormat.epub.rawValue
            streamingSession = nil
        case .streamed(let session):
            bookData = nil
            bookExtension = EbookFormat.epub.rawValue
            streamingSession = session
        }
        self.sessionData = sessionData
        self.handlerName = handlerName
        self.capability = capability
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
            url.scheme == FoliateRuntimeSupport.scheme,
            url.host == FoliateRuntimeSupport.host,
            FoliateRuntimeSupport.isAllowedRuntimePath(url.path),
            isAllowedURL(url),
            urlSchemeTask.request.httpMethod == nil || urlSchemeTask.request.httpMethod == "GET"
        else {
            fail(urlSchemeTask, code: 403)
            return
        }

        if url.path.hasPrefix(FoliateRuntimeSupport.streamedResourcePrefix) {
            serveStreamedResource(urlSchemeTask, url: url)
            return
        }

        let data: Data
        let mimeType: String
        switch url.path {
        case "/session.json":
            data = sessionData
            mimeType = "application/json"
        case "/book/current.\(bookExtension)":
            guard let bookData else {
                fail(urlSchemeTask, code: 404)
                return
            }
            data = bookData
            mimeType = bookExtension == EbookFormat.fb2.rawValue
                ? EbookFormat.fb2.mimeType
                : EbookFormat.epub.mimeType
        default:
            let relativePath = String(url.path.dropFirst())
            let fileURL = runtimeRoot.appendingPathComponent(relativePath)
            guard fileURL.standardizedFileURL.path.hasPrefix(runtimeRoot.standardizedFileURL.path + "/"),
                let loaded = try? Data(contentsOf: fileURL)
            else {
                fail(urlSchemeTask, code: 404)
                return
            }
            data = loaded
            switch fileURL.pathExtension.lowercased() {
            case "html":
                mimeType = "text/html"
            case "css":
                mimeType = "text/css"
            default:
                mimeType = "text/javascript"
            }
        }
        respond(urlSchemeTask, url: url, data: data, mimeType: mimeType)
    }

    private func serveStreamedResource(_ urlSchemeTask: any WKURLSchemeTask, url: URL) {
        guard let session = streamingSession else {
            fail(urlSchemeTask, code: 404)
            return
        }
        let path = String(url.path.dropFirst(FoliateRuntimeSupport.streamedResourcePrefix.count))
        guard let entry = session.entry(atPath: path) else {
            fail(urlSchemeTask, code: 404)
            return
        }
        let taskID = ObjectIdentifier(urlSchemeTask)
        liveResourceTasks[taskID] = Task { [weak self] in
            let loaded = try? await session.resourceData(atPath: path)

            guard let self, self.liveResourceTasks.removeValue(forKey: taskID) != nil else { return }
            if let loaded {
                self.respond(urlSchemeTask, url: url, data: loaded, mimeType: entry.mediaType ?? "application/octet-stream")
            } else {
                self.fail(urlSchemeTask, code: 404)
            }
        }
    }

    private func respond(_ urlSchemeTask: any WKURLSchemeTask, url: URL, data: Data, mimeType: String) {
        let needsCharset =
            mimeType.hasPrefix("text/")
            || mimeType.contains("xml")
            || mimeType.contains("javascript")
            || mimeType.contains("json")
        let headers = [
            "Content-Type": needsCharset ? "\(mimeType); charset=utf-8" : mimeType,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Cross-Origin-Resource-Policy": "same-origin",
        ]
        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
        else {
            fail(urlSchemeTask, code: 500)
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        liveResourceTasks[taskID]?.cancel()
        liveResourceTasks[taskID] = nil
    }

    private func isAllowedURL(_ url: URL) -> Bool {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.fragment == nil
        else {
            return false
        }
        if url.path == "/index.html" {
            let items = components.queryItems ?? []
            return items.count == 2
                && items.first(where: { $0.name == "handler" })?.value == handlerName
                && items.first(where: { $0.name == "capability" })?.value == capability
        }
        components.query = nil
        return components.url?.absoluteString == url.absoluteString
    }

    private func fail(_ task: any WKURLSchemeTask, code: Int) {
        task.didFailWithError(
            NSError(
                domain: "FoliateRuntime",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Blocked local reader resource"]
            )
        )
    }
}

private final class WeakFoliateMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: FoliateReaderEngineAdapter?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.receive(message)
    }
}

private struct FoliatePositionPayload {
    private static let keys: Set<String> = [
        "href", "cfi", "resourceProgression", "totalProgression", "chapterTitle",
        "pageCurrent", "pageTotal", "exact", "prefix", "suffix", "cssSelector", "domRange",
    ]

    let href: String
    let cfi: String?
    let resourceProgression: Double?
    let totalProgression: Double
    let chapterTitle: String
    let pageCurrent: Int?
    let pageTotal: Int?
    let exact: String?
    let prefix: String?
    let suffix: String?
    let cssSelector: String?
    let domRange: [String: Any]?

    init(json: [String: Any]) throws {
        guard Set(json.keys) == Self.keys,
            let href = json["href"] as? String,
            let chapterTitle = json["chapterTitle"] as? String,
            let totalProgression = Self.finiteDouble(json["totalProgression"]),
            (0...1).contains(totalProgression)
        else {
            throw FoliateReaderError.invalidRuntimeMessage
        }
        self.href = href
        self.cfi = try Self.optionalString(json["cfi"])
        self.resourceProgression = try Self.optionalFraction(json["resourceProgression"])
        self.totalProgression = totalProgression
        self.chapterTitle = chapterTitle
        self.pageCurrent = try Self.optionalInteger(json["pageCurrent"])
        self.pageTotal = try Self.optionalInteger(json["pageTotal"])
        self.exact = try Self.optionalString(json["exact"])
        self.prefix = try Self.optionalString(json["prefix"])
        self.suffix = try Self.optionalString(json["suffix"])
        self.cssSelector = try Self.optionalString(json["cssSelector"])
        if json["domRange"] is NSNull {
            domRange = nil
        } else if let value = json["domRange"] as? [String: Any],
            Self.validDOMRange(value)
        {
            domRange = value
        } else {
            throw FoliateReaderError.invalidRuntimeMessage
        }
    }

    var locatorJSON: String {
        var locations: [String: Any] = ["totalProgression": totalProgression]
        if let resourceProgression {
            locations["progression"] = resourceProgression
        }
        if let cfi = EpubLocationBridge.normalizedEPUBCFI(cfi) {
            locations["cfi"] = cfi
        }
        if let cssSelector {
            locations["cssSelector"] = cssSelector
        }
        if let domRange {
            locations["domRange"] = domRange
        }
        var object: [String: Any] = [
            "href": href,
            "type": "application/xhtml+xml",
            "locations": locations,
        ]
        if !chapterTitle.isEmpty {
            object["title"] = chapterTitle
        }
        if let exact, !exact.isEmpty {
            var text: [String: Any] = ["highlight": exact]
            if let prefix { text["before"] = prefix }
            if let suffix { text["after"] = suffix }
            object["text"] = text
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    var relocation: ReaderEngineRelocation? {
        guard let locator = try? Locator(jsonString: locatorJSON) else { return nil }
        let range: ClosedRange<Int>? = {
            guard let current = pageCurrent, let total = pageTotal,
                current > 0, total > 0, current <= total
            else {
                return nil
            }
            return current...current
        }()
        return ReaderEngineRelocation(
            locator: locator,
            locatorJSON: locatorJSON,
            visiblePageRange: range
        )
    }

    private static func optionalString(_ value: Any?) throws -> String? {
        if value is NSNull { return nil }
        guard let value = value as? String else {
            throw FoliateReaderError.invalidRuntimeMessage
        }
        return value
    }

    private static func optionalFraction(_ value: Any?) throws -> Double? {
        if value is NSNull { return nil }
        guard let value = finiteDouble(value), (0...1).contains(value) else {
            throw FoliateReaderError.invalidRuntimeMessage
        }
        return value
    }

    private static func optionalInteger(_ value: Any?) throws -> Int? {
        if value is NSNull { return nil }
        guard let value = integer(value), value >= 0 else {
            throw FoliateReaderError.invalidRuntimeMessage
        }
        return value
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double,
            double >= Double(Int.min), double <= Double(Int.max)
        else {
            return nil
        }
        return Int(double)
    }

    private static func validDOMRange(_ value: [String: Any]) -> Bool {
        let keys = Set(value.keys)
        guard keys == ["start", "end"] || keys == ["start"],
            let start = value["start"] as? [String: Any],
            validDOMPoint(start)
        else {
            return false
        }
        if value["end"] is NSNull || value["end"] == nil {
            return true
        }
        guard let end = value["end"] as? [String: Any] else { return false }
        return validDOMPoint(end)
    }

    private static func validDOMPoint(_ value: [String: Any]) -> Bool {
        let keys = Set(value.keys)
        guard
            keys == ["cssSelector", "textNodeIndex", "charOffset"]
                || keys == ["cssSelector", "textNodeIndex"],
            let selector = value["cssSelector"] as? String,
            !selector.isEmpty,
            let index = integer(value["textNodeIndex"]),
            index >= 0
        else {
            return false
        }
        if value["charOffset"] is NSNull || value["charOffset"] == nil {
            return true
        }
        guard let offset = integer(value["charOffset"]) else { return false }
        return offset >= 0
    }
}

@MainActor
final class FoliateReaderEngineAdapter: UIViewController, ReaderEngineAdapter {
    private static let bridgeVersion = 1

    private let handlerName: String
    private let capability: String
    private let expectedTopURL: URL
    private let messageHandler: WeakFoliateMessageHandler
    private let schemeHandler: FoliateURLSchemeHandler
    private var webView: WKWebView!
    private var outgoingSequence = 0
    private var incomingSequence = 0
    private var commandInFlight = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingCommandID: UUID?
    private var pendingCommandContinuation: CheckedContinuation<Data, Error>?
    private var commandExecutionTask: Task<Void, Never>?
    private var commandTimeoutTask: Task<Void, Never>?
    private var pageDragUpdateTask: Task<Void, Never>?
    private var pendingPageDragDelta = CGPoint.zero
    private var startupContinuation: CheckedContinuation<Void, Error>?
    private var startupTimeoutTask: Task<Void, Never>?
    private var hasStarted = false
    private var isReady = false
    private var isTornDown = false
    private var pendingRenderedRelocation: ReaderEngineRelocation?
    private(set) var currentLocatorJSON: String?
    private(set) var currentSelection: ReaderSelectionSnapshot?
    #if DEBUG
    private var footnoteFixtureActivationStarted = false
    #endif

    var onRelocation: ((ReaderEngineRelocation) -> Void)? {
        didSet {
            guard let onRelocation, let pendingRenderedRelocation else { return }
            self.pendingRenderedRelocation = nil
            onRelocation(pendingRenderedRelocation)
        }
    }
    var onSelectionChange: ((ReaderSelectionSnapshot?) -> Void)?
    var onAnnotationActivated: ((String) -> Void)?
    var onTap: ((CGPoint, CGSize) -> Void)?
    var onExternalLink: ((URL) -> Void)?

    var kind: ReaderEngineKind { .foliate }
    var viewController: UIViewController { self }
    private(set) var capabilities: Set<ReaderEngineCapability> = []

    static func make(
        source: FoliateBookSource,
        initialLocatorJSON: String?,
        initialProgression: Double,
        appearance: ClassicReaderAppearance,
        annotations: [ReaderAnnotation]
    ) async throws -> FoliateReaderEngineAdapter {
        guard FoliateRuntimeSupport.isPackaged,
            let runtimeRoot = FoliateRuntimeSupport.resourceRoot
        else {
            throw FoliateReaderError.runtimeUnavailable
        }
        let preferences = try FoliateReaderPreferences(appearance: appearance)
        let annotationPayloads = try annotations.compactMap(FoliateAnnotationPayload.make)
        guard Set(annotationPayloads.map(\.cfi)).count == annotationPayloads.count else {
            throw FoliateReaderError.unsupportedAnnotation
        }
        let streamingJSON: Any
        let fileExtension: String
        switch source {
        case .file(_, let sourceExtension):
            streamingJSON = NSNull()
            fileExtension = sourceExtension.lowercased() == EbookFormat.fb2.rawValue
                ? EbookFormat.fb2.rawValue
                : EbookFormat.epub.rawValue
        case .streamed(let streamingSession):
            fileExtension = EbookFormat.epub.rawValue
            streamingJSON = [
                "sizes": streamingSession.sizesByPath.reduce(into: [String: Any]()) {
                    $0[$1.key] = NSNumber(value: $1.value)
                }
            ]
        }
        let session: [String: Any] = [
            "version": bridgeVersion,
            "initialLocatorJSON": initialLocatorJSON ?? NSNull(),
            "initialProgression": min(max(initialProgression, 0), 1),
            "preferences": preferences.jsonObject,
            "annotations": annotationPayloads.map(\.jsonObject),
            "fileExtension": fileExtension,
            "streaming": streamingJSON,
        ]
        guard JSONSerialization.isValidJSONObject(session) else {
            throw FoliateReaderError.invalidRuntimeMessage
        }
        let sessionData = try JSONSerialization.data(withJSONObject: session)
        let ruleList = try await makeNetworkBlocker()
        let adapter = try FoliateReaderEngineAdapter(
            runtimeRoot: runtimeRoot,
            source: source,
            sessionData: sessionData,
            ruleList: ruleList
        )
        try await adapter.start()
        return adapter
    }

    private static func makeNetworkBlocker() async throws -> WKContentRuleList {
        return try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "enve-foliate-block-network-v1",
                encodedContentRuleList: FoliateRuntimeSupport.networkBlockerSource
            ) { ruleList, error in
                if let ruleList {
                    continuation.resume(returning: ruleList)
                } else {
                    continuation.resume(
                        throwing: error ?? FoliateReaderError.networkBlockerUnavailable
                    )
                }
            }
        }
    }

    private init(
        runtimeRoot: URL,
        source: FoliateBookSource,
        sessionData: Data,
        ruleList: WKContentRuleList
    ) throws {
        handlerName = "enveFoliate" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        capability = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        var components = URLComponents()
        components.scheme = FoliateRuntimeSupport.scheme
        components.host = FoliateRuntimeSupport.host
        components.path = "/index.html"
        components.queryItems = [
            URLQueryItem(name: "handler", value: handlerName),
            URLQueryItem(name: "capability", value: capability),
        ]
        guard let topURL = components.url else {
            throw FoliateReaderError.runtimeUnavailable
        }
        expectedTopURL = topURL
        messageHandler = WeakFoliateMessageHandler()
        schemeHandler = try FoliateURLSchemeHandler(
            runtimeRoot: runtimeRoot,
            source: source,
            sessionData: sessionData,
            handlerName: handlerName,
            capability: capability
        )
        super.init(nibName: nil, bundle: nil)

        let userContentController = WKUserContentController()
        userContentController.add(messageHandler, name: handlerName)
        userContentController.add(ruleList)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: FoliateRuntimeSupport.scheme
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        messageHandler.target = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
        ])
        view = root
    }

    private func start() async throws {
        guard !hasStarted else {
            guard isReady else { throw FoliateReaderError.commandFailed }
            return
        }
        hasStarted = true
        loadViewIfNeeded()
        try await withCheckedThrowingContinuation { continuation in
            startupContinuation = continuation
            startupTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.finishStartup(.failure(FoliateReaderError.startupTimedOut))
            }
            webView.load(URLRequest(url: expectedTopURL))
        }
    }

    private func finishStartup(_ result: Result<Void, Error>) {
        guard let continuation = startupContinuation else { return }
        startupContinuation = nil
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        switch result {
        case .success:
            isReady = true
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func receive(_ message: WKScriptMessage) {
        do {
            guard !isTornDown,
                message.frameInfo.isMainFrame,
                message.frameInfo.request.url?.absoluteString == expectedTopURL.absoluteString,
                let envelope = message.body as? [String: Any],
                Set(envelope.keys) == ["version", "capability", "sequence", "type", "payload"],
                Self.integer(envelope["version"]) == Self.bridgeVersion,
                envelope["capability"] as? String == capability,
                let sequence = Self.integer(envelope["sequence"]),
                sequence == incomingSequence + 1,
                let type = envelope["type"] as? String,
                let payload = envelope["payload"] as? [String: Any]
            else {
                throw FoliateReaderError.invalidRuntimeMessage
            }
            incomingSequence = sequence
            try receive(type: type, payload: payload)
        } catch {
            if startupContinuation != nil {
                finishStartup(.failure(error))
            } else {
                AppLogger.library.error("Rejected Foliate runtime event: \(error.localizedDescription)")
            }
        }
    }

    private func receive(type: String, payload: [String: Any]) throws {
        switch type {
        case "ready":
            guard Set(payload.keys) == ["capabilities"],
                let rawCapabilities = payload["capabilities"] as? [String],
                rawCapabilities.count == Set(rawCapabilities).count
            else {
                throw FoliateReaderError.invalidRuntimeMessage
            }
            let received = Set(rawCapabilities.compactMap(ReaderEngineCapability.init(rawValue:)))
            guard received.count == rawCapabilities.count,
                received == FoliateRuntimeSupport.requiredCapabilities
            else {
                throw FoliateReaderError.missingCapabilities
            }
            capabilities = received
            finishStartup(.success(()))
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--activate-first-footnote") {
                Task { await activateFirstFootnoteForTesting() }
            }
            #endif

        case "relocate":
            guard Set(payload.keys) == ["locator", "reason"],
                let object = payload["locator"] as? [String: Any],
                payload["reason"] is NSNull || payload["reason"] is String
            else {
                throw FoliateReaderError.invalidRuntimeMessage
            }
            let position = try FoliatePositionPayload(json: object)
            guard let baseRelocation = position.relocation else {
                throw FoliateReaderError.invalidRuntimeMessage
            }
            let reason = payload["reason"] as? String
            let isUserInitiated: Bool
            if let reason {
                isUserInitiated = ["page", "snap", "scroll"].contains(reason)
            } else {
                isUserInitiated = false
            }
            let relocation = ReaderEngineRelocation(
                locator: baseRelocation.locator,
                locatorJSON: baseRelocation.locatorJSON,
                visiblePageRange: baseRelocation.visiblePageRange,
                isUserInitiated: isUserInitiated
            )
            currentLocatorJSON = relocation.locatorJSON
            if let onRelocation {
                onRelocation(relocation)
            } else {
                pendingRenderedRelocation = relocation
            }

        case "selection":
            guard Set(payload.keys) == ["selection"] else {
                throw FoliateReaderError.invalidRuntimeMessage
            }
            if payload["selection"] is NSNull {
                currentSelection = nil
                onSelectionChange?(nil)
                return
            }
            guard let selection = payload["selection"] as? [String: Any],
                Set(selection.keys) == ["locator", "frame"],
                let locatorObject = selection["locator"] as? [String: Any],
                let frame = selection["frame"] as? [String: Any],
                Set(frame.keys) == ["x", "y", "width", "height"],
                let x = Self.finiteDouble(frame["x"]),
                let y = Self.finiteDouble(frame["y"]),
                let width = Self.finiteDouble(frame["width"]),
                let height = Self.finiteDouble(frame["height"]),
                width >= 0, height >= 0
            else {
                throw FoliateReaderError.invalidRuntimeMessage
            }
            let position = try FoliatePositionPayload(json: locatorObject)
            guard let relocation = position.relocation else {
                throw FoliateReaderError.invalidRuntimeMessage
            }
            let snapshot = ReaderSelectionSnapshot(
                locator: relocation.locator,
                locatorJSON: relocation.locatorJSON,
                frame: CGRect(x: x, y: y, width: width, height: height),
                epubCFI: position.cfi
            )
            currentSelection = snapshot
            onSelectionChange?(snapshot)

        case "annotationActivated":
            guard Set(payload.keys) == ["id"],
                let id = payload["id"] as? String,
                !id.isEmpty
            else {
                throw FoliateReaderError.invalidRuntimeMessage
            }
            onAnnotationActivated?(id)

        case "tap":
            guard Set(payload.keys) == ["x", "y", "width", "height"],
                let x = Self.finiteDouble(payload["x"]),
                let y = Self.finiteDouble(payload["y"]),
                let width = Self.finiteDouble(payload["width"]),
                let height = Self.finiteDouble(payload["height"]),
                width > 0, height > 0
            else {
                throw FoliateReaderError.invalidRuntimeMessage
            }
            onTap?(CGPoint(x: x, y: y), CGSize(width: width, height: height))

        case "externalLink":
            guard Set(payload.keys) == ["url"],
                let value = payload["url"] as? String,
                let url = URL(string: value),
                let scheme = url.scheme?.lowercased(),
                ["http", "https"].contains(scheme),
                url.host?.isEmpty == false
            else {
                throw FoliateReaderError.invalidRuntimeMessage
            }
            onExternalLink?(url)

        case "error":
            guard Set(payload.keys) == ["message"],
                let message = payload["message"] as? String
            else {
                throw FoliateReaderError.invalidRuntimeMessage
            }
            let error = NSError(
                domain: "FoliateRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            if startupContinuation != nil {
                finishStartup(.failure(error))
            } else {
                AppLogger.library.error("Foliate runtime error: \(message)")
            }

        default:
            throw FoliateReaderError.invalidRuntimeMessage
        }
    }

    func restore(locatorJSON: String, animated: Bool) async -> Bool {
        guard
            let result = try? await command(
                "restore",
                payload: ["locatorJSON": locatorJSON, "animated": animated]
            ), Set(result.keys) == ["restored"]
        else {
            return false
        }
        return result["restored"] as? Bool == true
    }

    func navigate(to locator: Locator, animated: Bool) async -> Bool {
        guard let json = try? locator.jsonString() else { return false }
        return await restore(locatorJSON: json, animated: animated)
    }

    func navigate(toHref href: String, animated: Bool) async -> Bool {
        guard
            let result = try? await command(
                "href",
                payload: ["href": href, "animated": animated]
            ), Set(result.keys) == ["moved"]
        else {
            return false
        }
        return result["moved"] as? Bool == true
    }

    func navigate(toFraction fraction: Double, animated: Bool) async -> Bool {
        guard
            let result = try? await command(
                "fraction",
                payload: [
                    "fraction": min(max(fraction, 0), 1),
                    "animated": animated,
                ]
            ), Set(result.keys) == ["moved"]
        else {
            return false
        }
        return result["moved"] as? Bool == true
    }

    func pageForward(animated: Bool) async -> Bool {
        guard
            let result = try? await command(
                "next",
                payload: ["animated": animated]
            ), Set(result.keys) == ["moved"]
        else {
            return false
        }
        return result["moved"] as? Bool == true
    }

    func pageBackward(animated: Bool) async -> Bool {
        guard
            let result = try? await command(
                "previous",
                payload: ["animated": animated]
            ), Set(result.keys) == ["moved"]
        else {
            return false
        }
        return result["moved"] as? Bool == true
    }

    func updateInteractivePageDrag(delta: CGPoint) {
        guard !isTornDown else { return }
        pendingPageDragDelta.x += delta.x
        pendingPageDragDelta.y += delta.y
        guard pageDragUpdateTask == nil else { return }
        pageDragUpdateTask = Task { @MainActor [weak self] in
            await self?.flushInteractivePageDrag()
        }
    }

    func endInteractivePageDrag(velocity: CGPoint) {
        let updateTask = pageDragUpdateTask
        Task { @MainActor [weak self] in
            if let updateTask {
                await updateTask.value
            }
            guard let self, !isTornDown else { return }
            _ = try? await command(
                "pageDragEnd",
                payload: [
                    "velocityX": min(max(velocity.x, -5), 5),
                    "velocityY": min(max(velocity.y, -5), 5),
                ]
            )
        }
    }

    func refreshSelection() async -> Bool {
        guard let result = try? await command("refreshSelection", payload: [:]),
            Set(result.keys) == ["available"]
        else {
            return false
        }
        return result["available"] as? Bool == true
    }

    func clearSelection() {
        currentSelection = nil
        onSelectionChange?(nil)
        Task { [weak self] in
            guard let self else { return }
            _ = try? await command("clearSelection", payload: [:])
        }
    }

    func applyAppearance(_ appearance: ClassicReaderAppearance) async {
        do {
            let preferences = try FoliateReaderPreferences(appearance: appearance)
            let result = try await command(
                "preferences",
                payload: ["preferences": preferences.jsonObject]
            )
            guard Set(result.keys) == ["applied"],
                result["applied"] as? Bool == true
            else {
                throw FoliateReaderError.commandFailed
            }
        } catch {
            AppLogger.library.error("Unable to apply Foliate appearance: \(error.localizedDescription)")
        }
    }

    func updateAnnotations(_ annotations: [ReaderAnnotation]) async {
        do {
            let payloads = try annotations.compactMap(FoliateAnnotationPayload.make)
            guard Set(payloads.map(\.cfi)).count == payloads.count else {
                throw FoliateReaderError.unsupportedAnnotation
            }
            let result = try await command(
                "annotations",
                payload: ["annotations": payloads.map(\.jsonObject)]
            )
            guard Set(result.keys) == ["applied"],
                result["applied"] as? Bool == true
            else {
                throw FoliateReaderError.commandFailed
            }
        } catch {
            AppLogger.library.error("Unable to render Foliate annotations: \(error.localizedDescription)")
        }
    }

    func search(query: String) async -> [EbookSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let result = try? await command("search", payload: ["query": trimmed]),
            Set(result.keys) == ["results"],
            let rawResults = result["results"] as? [[String: Any]]
        else {
            return []
        }
        return rawResults.compactMap { item in
            guard Set(item.keys) == ["locator"],
                let object = item["locator"] as? [String: Any],
                let position = try? FoliatePositionPayload(json: object),
                let relocation = position.relocation
            else {
                return nil
            }
            return EbookSearchResult(
                text: relocation.locator.text.highlight ?? trimmed,
                locator: relocation.locator,
                locatorJSON: relocation.locatorJSON,
                chapterTitle: relocation.locator.title,
                contextBefore: relocation.locator.text.before ?? "",
                contextAfter: relocation.locator.text.after ?? ""
            )
        }
    }

    func clearSearch() async {
        _ = try? await command("clearSearch", payload: [:])
    }

    func setAutoScroll(pointsPerSecond: Double) async {
        _ = try? await command(
            "autoScroll",
            payload: ["pointsPerSecond": min(max(pointsPerSecond, 0), 500)]
        )
    }

    func currentPageText() async -> String? {
        guard let result = try? await command("pageText", payload: [:]),
            Set(result.keys) == ["text"]
        else {
            return nil
        }
        return result["text"] as? String
    }

    func flushPosition() async -> String? {
        guard let result = try? await command("flush", payload: [:]),
            Set(result.keys) == ["locator"],
            let object = result["locator"] as? [String: Any],
            let position = try? FoliatePositionPayload(json: object),
            let relocation = position.relocation
        else {
            return currentLocatorJSON
        }
        currentLocatorJSON = relocation.locatorJSON
        return relocation.locatorJSON
    }

    func ttsLocator(at point: CGPoint?) async -> Locator? {
        let commandName = point == nil ? "ttsStart" : "ttsAt"
        let payload = point.map { ["x": $0.x, "y": $0.y] } ?? [:]
        guard let result = try? await command(commandName, payload: payload),
            Set(result.keys) == ["locator"],
            let object = result["locator"] as? [String: Any],
            let position = try? FoliatePositionPayload(json: object),
            let relocation = position.relocation
        else {
            return currentLocatorJSON.flatMap { try? Locator(jsonString: $0) }
        }
        return relocation.locator
    }

    func applyTTSDecoration(locatorJSON: String?) async {
        let payload: [String: Any] = ["locatorJSON": locatorJSON ?? NSNull()]
        _ = try? await command("tts", payload: payload)
    }

    func followTTS(locatorJSON: String) async {
        _ = try? await command("ttsFollow", payload: ["locatorJSON": locatorJSON])
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        pageDragUpdateTask?.cancel()
        pageDragUpdateTask = nil
        pendingPageDragDelta = .zero
        if let pendingCommandID {
            finishCommand(
                id: pendingCommandID,
                result: .failure(CancellationError())
            )
        }
        startupTimeoutTask?.cancel()
        if startupContinuation != nil {
            finishStartup(.failure(CancellationError()))
        }
        for waiter in commandWaiters {
            waiter.resume()
        }
        commandWaiters.removeAll()
        let userContentController = webView.configuration.userContentController
        userContentController.removeScriptMessageHandler(forName: handlerName)
        messageHandler.target = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        onRelocation = nil
        onSelectionChange = nil
        onAnnotationActivated = nil
        onTap = nil
        onExternalLink = nil
    }

    private func command(
        _ type: String,
        payload: [String: Any]
    ) async throws -> [String: Any] {
        await acquireCommandSlot()
        defer { releaseCommandSlot() }
        try Task.checkCancellation()
        guard isReady, !isTornDown,
            JSONSerialization.isValidJSONObject(payload)
        else {
            throw FoliateReaderError.commandFailed
        }
        outgoingSequence += 1
        let envelope: [String: Any] = [
            "version": Self.bridgeVersion,
            "capability": capability,
            "sequence": outgoingSequence,
            "type": type,
            "payload": payload,
        ]
        let data = try await withCheckedThrowingContinuation { continuation in
            let commandID = UUID()
            pendingCommandID = commandID
            pendingCommandContinuation = continuation
            commandTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.finishCommand(
                    id: commandID,
                    result: .failure(FoliateReaderError.commandTimedOut)
                )
            }
            commandExecutionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let value = try await webView.callAsyncJavaScript(
                        "return await globalThis.EnveFoliateRuntime.command(command);",
                        arguments: ["command": envelope],
                        in: nil,
                        contentWorld: .page
                    )
                    guard let result = value as? [String: Any] else {
                        throw FoliateReaderError.commandFailed
                    }
                    let data = try JSONSerialization.data(withJSONObject: result)
                    finishCommand(id: commandID, result: .success(data))
                } catch {
                    finishCommand(id: commandID, result: .failure(error))
                }
            }
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FoliateReaderError.commandFailed
        }
        return result
    }

    #if DEBUG
    func activateFirstFootnoteForTesting() async -> Bool {
        guard !footnoteFixtureActivationStarted else { return false }
        footnoteFixtureActivationStarted = true
        let selector =
            ProcessInfo.processInfo.arguments.contains("--activate-cross-footnote")
            ? "#ref-cross"
            : "#ref-local"
        for _ in 0..<50 {
            if let result = try? await webView.callAsyncJavaScript(
                """
                const reader = document.querySelector('foliate-view');
                const content = reader?.renderer?.getContents?.()[0];
                const link = content?.doc?.querySelector(selector) ?? Array.from(content?.doc?.querySelectorAll('a') ?? []).find(element => {
                    const semantics = `${element.getAttribute('epub:type') ?? ''} ${element.getAttribute('role') ?? ''}`;
                    return semantics.split(/\\s+/).some(value => value === 'noteref' || value === 'doc-noteref');
                });
                if (!link) return false;
                const rawHref = link.getAttribute('href');
                const href = reader.book.sections[content.index]?.resolveHref?.(rawHref) ?? rawHref;
                reader.dispatchEvent(new CustomEvent('link', {
                    detail: { a: link, href },
                    cancelable: true,
                }));
                return true;
                """,
                arguments: ["selector": selector],
                in: nil,
                contentWorld: .page
            ),
                result as? Bool == true
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
    #endif

    private func flushInteractivePageDrag() async {
        while !Task.isCancelled {
            let delta = pendingPageDragDelta
            pendingPageDragDelta = .zero
            guard delta != .zero else { break }
            guard
                let result = try? await command(
                    "pageDrag",
                    payload: [
                        "deltaX": min(max(delta.x, -2000), 2000),
                        "deltaY": min(max(delta.y, -2000), 2000),
                    ]
                ), result["applied"] as? Bool == true
            else {
                break
            }
        }
        pageDragUpdateTask = nil
    }

    private func finishCommand(
        id: UUID,
        result: Result<Data, Error>
    ) {
        guard pendingCommandID == id,
            let continuation = pendingCommandContinuation
        else {
            return
        }
        pendingCommandID = nil
        pendingCommandContinuation = nil
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        commandExecutionTask?.cancel()
        commandExecutionTask = nil
        continuation.resume(with: result)
    }

    private func acquireCommandSlot() async {
        if !commandInFlight {
            commandInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            commandWaiters.append(continuation)
        }
    }

    private func releaseCommandSlot() {
        guard !commandWaiters.isEmpty else {
            commandInFlight = false
            return
        }
        commandWaiters.removeFirst().resume()
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value,
            value >= Double(Int.min), value <= Double(Int.max)
        else {
            return nil
        }
        return Int(value)
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }
}

extension FoliateReaderEngineAdapter: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            return .cancel
        }
        if navigationAction.targetFrame?.isMainFrame != false {
            return url.absoluteString == expectedTopURL.absoluteString ? .allow : .cancel
        }
        return scheme == "blob" || scheme == "about" ? .allow : .cancel
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        guard let url = navigationResponse.response.url else { return .cancel }
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https" ? .cancel : .allow
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        if startupContinuation != nil {
            finishStartup(.failure(error))
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        if startupContinuation != nil {
            finishStartup(.failure(error))
        }
    }
}

extension FoliateReaderEngineAdapter: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}
