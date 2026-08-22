import Foundation
import Logging

extension PlexService {
    func parsePlexAudiobooksXML(data: Data, serverUrl: String, token: String, sectionKey: String, sectionTitle: String?) throws -> [Book] {
        let parser = XMLParser(data: data)
        let delegate = PlexAudiobooksXMLParser(serverUrl: serverUrl, token: token, sectionKey: sectionKey, sectionTitle: sectionTitle)
        parser.delegate = delegate

        guard parser.parse() else {
            if let error = delegate.parseError {
                throw PlexError.decodingError(error)
            }
            throw PlexError.decodingError(
                NSError(domain: "XMLParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse XML"])
            )
        }

        return delegate.books
    }

    func parsePlexSectionsXML(data: Data) throws -> [LibrarySection] {
        let parser = XMLParser(data: data)
        let delegate = PlexSectionsXMLParser()
        parser.delegate = delegate

        guard parser.parse() else {
            if let error = delegate.parseError {
                throw PlexError.decodingError(error)
            }
            throw PlexError.decodingError(
                NSError(domain: "XMLParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse XML"])
            )
        }

        return delegate.sections.map { section in
            LibrarySection(
                id: section.key,
                key: section.key,
                title: section.title,
                type: section.type,
                serverId: nil,
                backendId: nil
            )
        }
    }
}

func parsePlexResourcesXML(data: Data) throws -> [PlexResourceParsed] {
    let parser = XMLParser(data: data)
    let delegate = PlexResourcesXMLParser()
    parser.delegate = delegate

    guard parser.parse() else {
        if let error = delegate.parseError {
            throw PlexError.decodingError(error)
        }
        throw PlexError.decodingError(NSError(domain: "XMLParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse XML"]))
    }

    return delegate.resources
}

func parseSharedServersXML(data: Data) throws -> [PlexSharedServerParsed] {
    let parser = XMLParser(data: data)
    let delegate = PlexSharedServersXMLParser()
    parser.delegate = delegate

    guard parser.parse() else {
        if let error = delegate.parseError {
            throw PlexError.decodingError(error)
        }
        throw PlexError.decodingError(
            NSError(domain: "XMLParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse shared servers XML"])
        )
    }

    return delegate.sharedServers
}

func parsePlexCollectionsXML(data: Data, serverUrl: String, token: String, sectionKey: String) throws -> [PlexCollection] {
    let parser = XMLParser(data: data)
    let delegate = PlexCollectionsXMLParser(serverUrl: serverUrl, token: token, sectionKey: sectionKey)
    parser.delegate = delegate

    guard parser.parse() else {
        if let error = delegate.parseError {
            throw PlexError.decodingError(error)
        }
        throw PlexError.decodingError(NSError(domain: "XMLParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse XML"]))
    }

    return delegate.collections
}

func parsePlexChaptersXML(data: Data) throws -> [Chapter] {
    let parser = XMLParser(data: data)
    let delegate = PlexChaptersXMLParser()
    parser.delegate = delegate

    guard parser.parse() else {
        if let error = delegate.parseError {
            throw PlexError.decodingError(error)
        }
        throw PlexError.decodingError(
            NSError(domain: "XMLParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse chapters XML"])
        )
    }

    return delegate.chapters
}

struct PlexResourceParsed {
    var name: String
    var clientIdentifier: String
    var provides: String
    var uri: String?
    var owned: Bool
    var synced: Bool
    var accessToken: String?
    var connections: [PlexConnectionParsed]
}

struct PlexConnectionParsed {
    let uri: String
    let local: Bool
    let `protocol`: String?
    let address: String?
    let port: Int?
    let relay: Bool?
}

struct PlexSharedServerParsed {
    let userId: String?
    let accessToken: String

    func matches(userId: String) -> Bool {
        self.userId == userId
    }
}

private class PlexResourcesXMLParser: NSObject, XMLParserDelegate {
    var resources: [PlexResourceParsed] = []
    var currentDevice: PlexResourceParsed?
    var currentConnection: PlexConnectionParsed?
    var currentElement: String = ""
    var parseError: Error?

    private static func parseBool(_ value: String?) -> Bool {
        guard let v = value?.lowercased() else { return false }
        return v == "1" || v == "true"
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        let lowerName = elementName.lowercased()

        if lowerName == "device" || lowerName == "resource" {
            let provides = attributeDict["provides"] ?? ""
            let owned = Self.parseBool(attributeDict["owned"])
            let name = attributeDict["name"] ?? ""
            let clientIdentifier = attributeDict["clientIdentifier"] ?? ""
            let uri = attributeDict["uri"]
            let synced = Self.parseBool(attributeDict["synced"])
            let accessToken = attributeDict["accessToken"]

            currentDevice = PlexResourceParsed(
                name: name,
                clientIdentifier: clientIdentifier,
                provides: provides,
                uri: uri,
                owned: owned,
                synced: synced,
                accessToken: accessToken,
                connections: []
            )
        } else if lowerName == "connection" {
            let uri = attributeDict["uri"] ?? ""
            let local = Self.parseBool(attributeDict["local"])
            let `protocol` = attributeDict["protocol"]
            let address = attributeDict["address"]
            let port = attributeDict["port"].flatMap { Int($0) }
            let relay = Self.parseBool(attributeDict["relay"])

            currentConnection = PlexConnectionParsed(
                uri: uri,
                local: local,
                protocol: `protocol`,
                address: address,
                port: port,
                relay: relay
            )
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let lowerName = elementName.lowercased()
        if lowerName == "device" || lowerName == "resource", let device = currentDevice {
            resources.append(device)
            currentDevice = nil
        } else if lowerName == "connection", let connection = currentConnection, var device = currentDevice {
            device.connections.append(connection)
            currentDevice = device
            currentConnection = nil
        }
        currentElement = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

private class PlexSharedServersXMLParser: NSObject, XMLParserDelegate {
    var sharedServers: [PlexSharedServerParsed] = []
    var parseError: Error?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "SharedServer" || elementName == "Server" else {
            return
        }

        guard let accessToken = attributeDict["accessToken"], !accessToken.isEmpty else {
            return
        }

        sharedServers.append(
            PlexSharedServerParsed(
                userId: attributeDict["userID"] ?? attributeDict["userId"] ?? attributeDict["invitedID"] ?? attributeDict["invitedId"]
                    ?? attributeDict["id"],
                accessToken: accessToken
            )
        )
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

private class PlexSectionsXMLParser: NSObject, XMLParserDelegate {
    var sections: [PlexSection] = []
    var currentSection: PlexSection?
    var currentElement: String = ""
    var currentText: String = ""
    var parseError: Error?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""

        if elementName == "Directory" {
            currentSection = PlexSection(
                key: attributeDict["key"] ?? "",
                title: attributeDict["title"] ?? "",
                type: attributeDict["type"] ?? ""
            )
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Directory", let section = currentSection {
            sections.append(section)
            currentSection = nil
        }
        currentElement = ""
        currentText = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

private struct PlexSection {
    let key: String
    let title: String
    let type: String
}

private class PlexCollectionsXMLParser: NSObject, XMLParserDelegate {
    let serverUrl: String
    let token: String
    let sectionKey: String
    var collections: [PlexCollection] = []
    var currentCollection: PlexCollectionParsed?
    var currentElement: String = ""
    var currentText: String = ""
    var parseError: Error?

    init(serverUrl: String, token: String, sectionKey: String) {
        self.serverUrl = serverUrl
        self.token = token
        self.sectionKey = sectionKey
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""

        if elementName == "Directory" && attributeDict["type"] == "collection" {
            let ratingKey = attributeDict["ratingKey"] ?? ""
            let title = attributeDict["title"] ?? "Unknown Collection"
            let summary = attributeDict["summary"]
            let thumb = attributeDict["thumb"]
            let childCount = attributeDict["childCount"].flatMap { Int($0) }

            var thumbUrl: String? = nil
            if let thumb = thumb {
                if thumb.hasPrefix("http") {
                    thumbUrl = thumb
                } else {
                    let baseUrl = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
                    thumbUrl = "\(baseUrl)\(thumb)?X-Plex-Token=\(token)"
                }
            }

            currentCollection = PlexCollectionParsed(
                ratingKey: ratingKey,
                title: title,
                summary: summary,
                thumb: thumbUrl,
                itemCount: childCount
            )
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Directory", let collection = currentCollection {
            let finalCollection = PlexCollection(
                id: collection.ratingKey,
                ratingKey: collection.ratingKey,
                title: collection.title,
                summary: collection.summary,
                thumb: collection.thumb,
                itemCount: collection.itemCount,
                sectionKey: sectionKey,
                serverUrl: serverUrl,
                token: token
            )
            collections.append(finalCollection)
            currentCollection = nil
        }
        currentElement = ""
        currentText = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

private struct PlexCollectionParsed {
    let ratingKey: String
    let title: String
    let summary: String?
    let thumb: String?
    let itemCount: Int?
}

private class PlexAudiobooksXMLParser: NSObject, XMLParserDelegate {
    let serverUrl: String
    let token: String
    let sectionKey: String
    let sectionTitle: String?
    var books: [Book] = []
    var currentTrack: PlexTrack?
    var currentMedia: PlexMedia?
    var currentPart: PlexPart?
    var savedPartKey: String?
    var savedFilePath: String?
    var currentItemEndElement: String?
    var currentElement: String = ""
    var parseError: Error?

    init(serverUrl: String, token: String, sectionKey: String, sectionTitle: String?) {
        self.serverUrl = serverUrl
        self.token = token
        self.sectionKey = sectionKey
        self.sectionTitle = sectionTitle
    }

    private func extractRatingKey(from attributes: [String: String]) -> String {
        if let ratingKey = attributes["ratingKey"], !ratingKey.isEmpty {
            return ratingKey
        }

        if let key = attributes["key"], !key.isEmpty {
            if let range = key.range(of: "/library/metadata/") {
                let rest = key[range.upperBound...]
                let id = rest.split(separator: "/").first.map(String.init) ?? ""
                if !id.isEmpty {
                    return id
                }
            }
            let last = key.split(separator: "/").last.map(String.init) ?? ""
            if !last.isEmpty, last.allSatisfy({ $0.isNumber }) {
                return last
            }
        }

        return ""
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName

        let elementType = attributeDict["type"]

        let isBookItemElement =
            elementName == "Track" || (elementName == "Metadata" && (elementType == "track" || elementType == "album"))
            || (elementName == "Directory" && (elementType == "album" || elementType == "track"))

        if isBookItemElement {
            savedPartKey = nil
            savedFilePath = nil
            currentItemEndElement = elementName

            let ratingKey = extractRatingKey(from: attributeDict)
            let title = attributeDict["title"] ?? "Unknown"
            let grandparentTitle = attributeDict["grandparentTitle"]
            let parentTitle = attributeDict["parentTitle"]
            let thumb = attributeDict["thumb"]
            let duration = attributeDict["duration"].flatMap { TimeInterval($0) }.map { $0 / 1000.0 }
            let addedAt = attributeDict["addedAt"].flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }

            let inferredType = elementType ?? (elementName == "Directory" ? "album" : "track")

            let bookTitle: String
            if inferredType == "track" {
                bookTitle = parentTitle ?? title
            } else {
                bookTitle = title
            }

            let author = grandparentTitle ?? parentTitle

            var thumbUrl: String? = nil
            if let thumb {
                if thumb.hasPrefix("http") {
                    thumbUrl = thumb
                } else {
                    let baseUrl = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
                    thumbUrl = "\(baseUrl)\(thumb)?X-Plex-Token=\(token)"
                }
            }

            currentTrack = PlexTrack(
                ratingKey: ratingKey.isEmpty ? "item_\(UUID().uuidString)" : ratingKey,
                title: bookTitle,
                author: author,
                thumb: thumbUrl,
                duration: duration,
                addedAt: addedAt
            )
        } else if elementName == "Media" {
            currentMedia = PlexMedia()
        } else if elementName == "Part" {
            let key = attributeDict["key"] ?? ""
            let file = attributeDict["file"]
            let duration = attributeDict["duration"].flatMap { TimeInterval($0) }.map { $0 / 1000.0 }

            if key.isEmpty {
                AppLogger.network.info("Part element found but key is empty")
            } else {
                if let file = file {
                    savedFilePath = file
                }
                savedPartKey = key
            }

            currentPart = PlexPart(key: key, duration: duration, file: file)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == currentItemEndElement, let track = currentTrack {
            let partKey = currentPart?.key ?? savedPartKey
            let filePath = currentPart?.file ?? savedFilePath

            if partKey == nil || partKey?.isEmpty == true {
                AppLogger.network.debug(
                    "Book missing part key diagnosticID=\(DiagnosticLogSanitizer.identifier(for: track.title))"
                )
            }

            let book = Book(
                id: track.ratingKey,
                ratingKey: track.ratingKey,
                title: track.title,
                author: track.author,
                narrator: nil,
                thumb: track.thumb,
                partKey: partKey,
                duration: track.duration ?? currentPart?.duration,
                chapters: nil,
                currentChapterIndex: nil,
                source: .plex,
                backendId: sectionKey,
                trackIndex: nil,
                filePath: filePath,
                audioTracks: nil,
                description: nil,
                series: nil,
                seriesNumber: nil,
                publishedYear: nil,
                genres: nil,
                publisher: nil,
                isbn: nil,
                asin: nil,
                addedAt: track.addedAt,
                libraryName: sectionKey,
                backendName: sectionTitle,
                progress: nil,
                lastPlayed: nil
            )

            books.append(book)
            currentTrack = nil
            currentMedia = nil
            currentPart = nil
            savedPartKey = nil
            currentItemEndElement = nil
        } else if elementName == "Media" {
            currentMedia = nil
        } else if elementName == "Part" {
            currentPart = nil
        }
        currentElement = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

private struct PlexTrack {
    let ratingKey: String
    let title: String
    let author: String?
    let thumb: String?
    let duration: TimeInterval?
    let addedAt: Date?
}

private struct PlexMedia {
}

private struct PlexPart {
    let key: String
    let duration: TimeInterval?
    let file: String?
}

private class PlexChaptersXMLParser: NSObject, XMLParserDelegate {
    var chapters: [Chapter] = []
    var currentChapter: PlexChapter?
    var currentElement: String = ""
    var parseError: Error?
    var inTrack = false
    var inVideo = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName

        if elementName == "Track" || elementName == "Video" {
            inTrack = (elementName == "Track")
            inVideo = (elementName == "Video")
            AppLogger.network.info("Found \(elementName) element")
        }

        if elementName == "Chapter" {
            AppLogger.network.info("Found Chapter element with attributes: \(attributeDict)")
            let baseId = attributeDict["id"] ?? ""

            let index = attributeDict["index"].flatMap { Int($0) } ?? (chapters.count + 1)

            var title = attributeDict["tag"] ?? attributeDict["title"] ?? attributeDict["name"] ?? attributeDict["summary"] ?? ""

            title = title.trimmingCharacters(in: .whitespacesAndNewlines)

            if title.isEmpty {
                title = "Chapter \(index)"
            }

            let startTimeOffset = attributeDict["startTimeOffset"].flatMap { Int64($0) }.map { TimeInterval($0) / 1000.0 } ?? 0
            let endTimeOffset = attributeDict["endTimeOffset"].flatMap { Int64($0) }.map { TimeInterval($0) / 1000.0 } ?? 0
            let duration = endTimeOffset > startTimeOffset ? endTimeOffset - startTimeOffset : 0

            let startTimeMs = Int(startTimeOffset * 1000)
            let id = baseId.isEmpty ? "chapter_\(chapters.count + 1)_\(startTimeMs)" : "\(baseId)_\(startTimeMs)"

            AppLogger.network.info(
                "Parsing chapter \(chapters.count + 1): id='\(id)', title='\(title)', index=\(index), start=\(startTimeOffset)s, end=\(endTimeOffset)s, duration=\(duration)s"
            )

            currentChapter = PlexChapter(
                id: id,
                title: title,
                startTime: startTimeOffset,
                endTime: endTimeOffset,
                duration: duration,
                index: index
            )
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Chapter", let chapter = currentChapter {
            var finalTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)

            if finalTitle.isEmpty || finalTitle.lowercased() == "chapter 1" || finalTitle.lowercased() == "chapter" {
                finalTitle = "Chapter \(chapter.index)"
            }

            let finalId: String
            if chapter.id.isEmpty {
                finalId = "chapter_\(chapter.index)_\(Int(chapter.startTime))"
            } else {
                finalId = chapter.id.contains("_\(Int(chapter.startTime))") ? chapter.id : "\(chapter.id)_\(Int(chapter.startTime))"
            }

            guard chapter.startTime >= 0 && chapter.duration > 0 else {
                AppLogger.network.error(
                    "Skipping chapter '\(finalTitle)' - invalid timing (start: \(chapter.startTime)s, duration: \(chapter.duration)s)"
                )
                currentChapter = nil
                currentElement = ""
                return
            }

            let swiftChapter = Chapter(
                id: finalId,
                start: chapter.startTime,
                end: chapter.endTime,
                title: finalTitle
            )
            AppLogger.network.info(
                "Added chapter \(chapters.count + 1): '\(finalTitle)' (id: \(finalId), start: \(chapter.startTime)s, end: \(chapter.endTime)s)"
            )
            chapters.append(swiftChapter)
            currentChapter = nil
        }

        if elementName == "Track" || elementName == "Video" {
            inTrack = false
            inVideo = false
        }

        currentElement = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

private struct PlexChapter {
    let id: String
    let title: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let duration: TimeInterval
    let index: Int
}
