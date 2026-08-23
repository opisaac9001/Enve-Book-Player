//
// EpubParser.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//

import Foundation
import ZIPFoundation


public struct EpubParser : AlignmentSessionProviding {
    public var session: AlignmentSession

    public init(session:AlignmentSession) {
        self.session = session
    }
    
    public func parse(url epubURL: URL ) async throws -> EpubDocument {
        try Task.checkCancellation()

        let fileManager = FileManager.default
        let tempDir = session.request.sessionDir.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: epubURL, to: tempDir)
        
        let containerPath = tempDir.appendingPathComponent("META-INF/container.xml")
        let containerData = try Data(contentsOf: containerPath)
        let container = try EpubContainerParser().parseContainer(from: containerData)
        
        let opfFullURL = tempDir.appendingPathComponent(container.opfPath)
        let opfData = try Data(contentsOf: opfFullURL)
        let metadata = try EpubMetaInfoParser().parseMetaInfo(from: opfData)
        let spine = try EpubSpineParser().parseSpine(from: opfData)
        let opfManifestItems = try EpubOpfManifestParser().parseManifest(from: opfData)
        
        session.progressTracker.updateProgress(for: .epub,  event:.start, total: opfManifestItems.count)

        
        var docResources:Set<URL> = []
        
        let nav:EpubNav? = try EpubNavParser().parseNav(from: opfFullURL, opfManifestItems: opfManifestItems )
        let ncx:Epub2Ncx? = try? EpubNcxParser().parseNcx( from:opfFullURL, opfManifestItems: opfManifestItems, spine: spine )


        let manifest = try opfManifestItems.compactMap { (opfManifestItem) -> EpubManifestItem? in
            try Task.checkCancellation()

            let itemName = nav?.title(for: opfManifestItem.href) ?? ncx?.title(for: opfManifestItem.href) ?? opfManifestItem.id

            guard let url = EpubOpfResolver.resolveHref(opfManifestItem.href, relativeTo: opfFullURL) else {
                throw StoryAlignError("Cannot find manifest item content" )
            }
            defer {
                session.progressTracker.updateProgress(for: .epub,increment: 1, item:itemName )
            }
            if opfManifestItem.mediaType != EpubMediaTypes.xhtmlXml {
                logger.log( .info, "Ignoring nonXhtmlItem in manifest: \(opfManifestItem.id)")
                return nil
            }

            logger.log(.info, "Parsing manifest item \(opfManifestItem.id)")
            let xmlData = try Data(contentsOf: url)
            let xmlText = String(data: xmlData, encoding: .utf8) ?? ""
            let (itemText, itemHasScript, itemResources) = try EpubXhtmlTextParser().parseText(from:xmlData )
            
            let itemResourceUrls = itemResources.map {
                url.deletingLastPathComponent().appendingPathComponent($0)
            }
            docResources.formUnion(itemResourceUrls)
            
            let granularity:Granularity = sessionConfig.granularity.useWordTokenizer ? .sentence : sessionConfig.granularity
            
            let xhtmlSentences = try EpubXhtmlTextParser.getXHtmlSentences(from: xmlText, granularity:granularity)

            let spineItemIndex = spine.item(forIdRef: opfManifestItem.id)?.index ?? -1

            let manifestItem = EpubManifestItem(
                id: opfManifestItem.id,
                href: opfManifestItem.href,
                mediaType: opfManifestItem.mediaType,
                properties: opfManifestItem.properties,
                spineItemIndex: spineItemIndex,
                text: itemText,
                xmlData: xmlData,
                hasScript: itemHasScript,
                xhtmlSentences: xhtmlSentences,
                name: itemName,
                filePath: url)

            return manifestItem
        }

        
        let guide = try Epub2GuideParser().parseGuide(from: opfData)
        
        let epub = try EpubDocument(opfPath: container.opfPath, opfXmlData: opfData, metaInfo: metadata, unzippedURL: tempDir, guide: guide, manifest: manifest, spine: spine, nav:nav, ncx:ncx, resources: Array(docResources))
        if !epub.isEpub2 && ((epub.nav?.landmarks.bodymatterHrefs.isEmpty) ?? true) {
            if sessionConfig.startManifestItemId == nil {
                logger.log(.warn, "EPUB is missing a 'bodymatter' marker (commonly recommended in EPUB3). If early alignment looks wrong, try configuring a start chapter.")
            }
        }
        
        progressTracker.updateProgress(for: .epub,  event: .end)
        
        return epub
    }
}



public extension EpubParser {
    static func chapterEntries( from epubURL:URL, logger:Logger ) throws -> [EpubChapterEntry]  {
        let archive = try Archive(url: epubURL, accessMode: .read)
        let containerData = try extractData(from: archive, path: "META-INF/container.xml")
        let container = try EpubContainerParser().parseContainer(from: containerData)
        
        let opfData = try extractData(from: archive, path: container.opfPath)
        let spine = try EpubSpineParser().parseSpine(from: opfData)
        let opfManifestItems = try EpubOpfManifestParser().parseManifest(from: opfData)
        let manifestById = EpubOpfResolver.manifestById(opfManifestItems)
        
        func chapters(using toc: some EpubNavOrNcx) -> [EpubChapterEntry] {
            spine.items.enumerated().compactMap { (index,spineItem) in
                guard let manifestItem = manifestById[spineItem.idref] else {
                    logger.log(.warn, "Spine references missing manifest id: \(spineItem.idref)")
                    return nil
                    //return EpubChapterEntry(manifestId: spineItem.idref, navLabel: spineItem.idref,
                }
                let title = toc.title(for: manifestItem.href)
                let resolvedTitle = title ?? spineItem.idref
                let role = toc.role(for: manifestItem.href) ?? (title == nil ? .unlisted : nil)
                return EpubChapterEntry(manifestId: spineItem.idref, navLabel: resolvedTitle, spineItemIndex: index, role: role)
            }
        }
        
        if let navItem = EpubOpfResolver.navManifestItem( opfManifestItems ) {
            let navPath = container.opfPath.deletingLastPathComponent().appendingPathComponent(navItem.href)
            let navData = try extractData(from: archive, path: navPath)
            let nav = try EpubNavParser().parseNav(from: navData,navManifestItem: navItem)
            return chapters(using: nav)
        }
        if let ncxItem = EpubOpfResolver.ncxManifestItem(opfManifestItems, spine: spine ) {
            let path = container.opfPath.deletingLastPathComponent().appendingPathComponent(ncxItem.href)
            let data = try extractData(from: archive, path: path)
            let ncx = try EpubNcxParser().parseNcx(from: data, ncxManifestItem: ncxItem)
            return chapters(using: ncx)
        }
        return []
    }

    static func extractData( from archive:Archive, path:String ) throws -> Data {
        guard let entry = archive[path] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }

        return data
    }
}


struct EpubOpfResolver {
    static func baseURL(opfURL: URL) -> URL {
        opfURL.deletingLastPathComponent()
    }

    static func resolveHref(_ href: String, relativeTo opfURL: URL) -> URL? {
        URL(string: href, relativeTo: baseURL(opfURL: opfURL))
    }

    static func navManifestItem(_ items: [OpfManifestItem]) -> OpfManifestItem? {
        items.first { $0.properties?.contains("nav") == true }
    }
    static func ncxManifestItem(_ items: [OpfManifestItem], spine:EpubSpine ) -> OpfManifestItem? {
        if !spine.toc.isEmpty {
            if let item = items.first(where:({ $0.id == spine.toc })) {
                return item
            }
        }
        if let item = items.first(where:({ $0.mediaType == EpubMediaTypes.ncxXml })) {
            return item
        }
        return items.first { $0.properties?.contains("ncx") == true }
    }

    static func navURL(opfURL: URL, manifestItems: [OpfManifestItem]) -> URL? {
        guard let navHref = navManifestItem(manifestItems)?.href else { return nil }
        return baseURL(opfURL: opfURL).appendingPathComponent(navHref)
    }

    static func manifestById(_ items: [OpfManifestItem]) -> [String: OpfManifestItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    static func spineURLs(opfURL: URL, manifestItemsById: [String: OpfManifestItem], spine: EpubSpine) -> [URL] {
        spine.items.compactMap { itemref in
            guard let m = manifestItemsById[itemref.idref] else { return nil }
            return baseURL(opfURL: opfURL).appendingPathComponent(m.href)
        }
    }
}
