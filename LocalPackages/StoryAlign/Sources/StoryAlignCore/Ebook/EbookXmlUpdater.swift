//
// EbookXmlUpdater.swift
//
// SPDX-License-Identifier: MIT
//
// Copyright (c) 2023 Shane Friedman
// Copyright (c) 2025 Rich Waters
//



import Foundation
import SwiftSoup

public struct EpubXmlUpdater : AlignmentSessionProviding,Sendable {
    public let session: AlignmentSession
    public init(session: AlignmentSession) {
        self.session = session
    }
    
    let cssStyle = """
        .-epub-media-overlay-active {
          background-color: #4FC3F7;
        }
        """
    
    public func update(epub: EpubDocument, audioBook: AudioBook, alignedChapters: [AlignedChapter]) async throws {
        try await tagAndWrite(alignedChapters: alignedChapters, inEbook: epub)
        let mediaOverlays = try createMediaOverlays(for: epub, alignedChapters: alignedChapters)
        try update(eBook: epub, mediaOverlays: mediaOverlays, audioFiles: audioBook.audioFiles)
        
        if epub.isEpub2 {
            let alignedManifestIds:[String] = alignedChapters.map { $0.manifestItem.id }
            let nonAlignedItems = epub.manifest.filter { !alignedManifestIds.contains( $0.id ) }
            for item in nonAlignedItems {
                guard let filePath = item.filePath else {
                    continue
                }
                if item.mediaType != "application/xhtml+xml" {
                    continue
                }
                let text = item.xmlText
                let doc = try SwiftSoup.parse(text)
                let nuText = try doc.xmlFormatted()
                try nuText.write(to: filePath, atomically: true, encoding: .utf8)
            }
        }
    }
}

extension EpubXmlUpdater {

    func tagAndWrite(alignedChapters: [AlignedChapter], inEbook: EpubDocument) async throws {
        let total = alignedChapters.count
        let totalBytes = alignedChapters.reduce(0) { $0 + $1.manifestItem.xmlText.count }
        
        progressTracker.updateProgress(for: .xml, event:.start, total: totalBytes )
        
        let nThreads = sessionConfig.concurrency
        let _ = try await alignedChapters.enumerated().asyncCompactMap(concurrency: nThreads) { (index,chapter) -> (URL, String)? in
            let manifestItem = chapter.manifestItem
            
            defer {
                progressTracker.updateProgress(for: .xml, increment: manifestItem.xmlText.count, item:chapter.manifestItem.name)
            }
            
            guard let filePath = manifestItem.filePath else {
                return nil
            }
            if chapter.alignedSentences.isEmpty {
                if !inEbook.isEpub2 {
                    return nil
                }
            }
            logger.log( .info, "Updating \(manifestItem.id)")
            let nuText = try await XHTMLTagger(session: session).tag(epub:inEbook, alignedChapter: chapter)
            try nuText.write(to: filePath, atomically: true, encoding: .utf8)
            logger.log( .info, "\(manifestItem.id) update complete. ( \(index)/\(total) )")
            return( filePath, nuText)
        }
        progressTracker.updateProgress(for: .xml, event:.end )
    }

    func createMediaOverlays(for epub: EpubDocument, alignedChapters: [AlignedChapter]) throws -> [MediaOverlay] {
        let mediaOverlays:[MediaOverlay] = alignedChapters.compactMap { (alignedChapter) -> MediaOverlay? in
            let manifestItem = alignedChapter.manifestItem
            if manifestItem.filePath == nil {
                return nil
            }
            if alignedChapter.allSentenceRanges.isEmpty {
                return nil
            }
            
            let alignedUnits = sessionConfig.granularity.useWordTokenizer ? alignedChapter.alignedWords : {
                guard let expansion = sessionConfig.granularityExpansion,
                      let _ = expansion.scope
                else {
                    return alignedChapter.alignedSentences
                }
                return alignedChapter.alignedWords
            }()
            
            let validSentenceRanges:[SentenceRange] = alignedUnits.compactMap {
                if $0.sentenceRange.duration == 0 {
                    logger.log( .info, "Skipping 0-duration sentence range for \($0.xhtmlSentence)")
                    return nil
                }
                return $0.sentenceRange
            }

            guard !validSentenceRanges.isEmpty else {
                logger.log(.info, "No valid sentence ranges for \(manifestItem.id) - skipping media overlay")
                return nil
            }

            logger.log(.info, "Creating MediaOverlay for \(manifestItem.id)")
            let tagPfx = sessionConfig.granularityExpansion != nil ? XHTMLTagger.wordTagPfx : XHTMLTagger.sentenceTagPfx

            let mo = MediaOverlay(baseURL: epub.opfURL.deletingLastPathComponent(), manifestItem: manifestItem, sentenceRanges: validSentenceRanges, sentenceTagPfx: tagPfx )
            logger.log(.info, "Completed MediaOverlay for \(manifestItem.id)")
            return mo
        }
        return mediaOverlays
    }

    func update(eBook: EpubDocument, mediaOverlays: [MediaOverlay], audioFiles: [AudioFile]) throws {
        logger.log(.info, "Updating OPF")
        
        let opfData = eBook.opfXmlData
        guard let xmlString = String(data: opfData, encoding: .utf8) else {
            throw StoryAlignError("Invalid OPF data")
        }
        let document = try SwiftSoup.parse(xmlString, "", Parser.xmlParser() )

        let epub2Converter = Epub2Converter()
        if eBook.isEpub2 {
            try epub2Converter.update(epub: eBook, doc: document)
        }
        try epub2Converter.cleanupNcx(epub: eBook, doc: document)
        
        try updateOpfContribAndModTime( in: document )
        try fixMissingResources(in: document, eBook: eBook)
        try fixScriptedIssues(in: document, eBook: eBook)

        try add(mediaOverlays: mediaOverlays, to: document, audioFiles: audioFiles)
        try addStyles(to: document, eBook: eBook)

        let updatedXMLStr = try document.xmlFormatted()
        try updatedXMLStr.write(to: eBook.opfURL, atomically: true, encoding: .utf8)

        logger.log(.info, "Completed OPF update")
    }
    
    func updateOpfContribAndModTime( in document:Document ) throws {
        guard let metadata = try document.select("metadata").first() else {
            throw StoryAlignError("Metadata not found.")
        }
        //<meta property="dcterms:modified">2025-04-10T02:38:54Z</meta>
        let isoFormatter = ISO8601DateFormatter()
        let dtModified = isoFormatter.string(from: Date())
        if let modifiedElement = try document.select("meta[property=\"dcterms:modified\"]").first() {
            try modifiedElement.text(dtModified)
        }
        else {
            logger.log(.warn, "Couldn't find dcterms:modified in epub -- adding one" )
            let meta = try DomHelpers.buildMeta(attributes: [("property","dcterms:modified")], text: dtModified)
            try metadata.appendChild(meta)
        }
        
        //<dc:contributor id="id-2"></dc:contributor>
        //<meta refines="#id-2" property="role" scheme="marc:relators">bkp</opf:meta>
        for (index,contributor) in sessionConfig.contributors.enumerated() {
            let idStr = "storyalign-contributor-id\(index+1)"
            //let versionStr = "\(sessionConfig.toolName ?? "StoryAlign") v\(sessionConfig.version ?? "???")"
            let versionStr = contributor
            let contributor = try DomHelpers.buildElement( withName:"dc:contributor", attributes: [("id",idStr)], text: versionStr)
            try metadata.appendChild(contributor)
            
            let refinesContributor = try DomHelpers.buildMeta( refines:idStr, property: "role", scheme: "marc:relators", text : "bkp" )
            try metadata.appendChild(refinesContributor)
        }
    }
    
    
    func fixScriptedIssues( in document:Document , eBook: EpubDocument ) throws {
        guard let manifest = try document.select("manifest").first() else {
            throw StoryAlignError("Missing manifest")
        }

        for item in eBook.manifest {
            let hasScript = {
                if item.hasScript ?? false {
                    return true
                }
                return false
            }()
            if hasScript {
                if let xmlItem = try manifest.select("item[id=\(item.id)]").first() {
                    var props = (try? xmlItem.attr("properties").split(separator: " ")) ?? []
                    if !props.contains("scripted") {
                        props.append("scripted")
                        try xmlItem.attr("properties", props.joined(separator: " "))
                    }
                }
            }
        }
    }
    
    func fixMissingResources( in document:Document , eBook: EpubDocument ) throws {
        guard let manifest = try document.select("manifest").first() else {
            throw StoryAlignError("Missing manifest")
        }
        let missingResources:[(href:String,itemId:String,mediaType:String)] = try eBook.resources.compactMap { url in
            if !FileManager.default.fileExists(atPath: url.path) {
                logger.log(.info, "Ignoring referenced resource that doesn't exist: \(url.path)")
                return nil
            }
            let href = url.relative(to: eBook.opfURL)
            let itemId = href.replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "_", options: .regularExpression)

            guard try document.select("item[href=\"\(href)\"]").first() == nil else {
                return nil
            }
            guard try document.select("item[id=\"\(itemId)\"]").first() == nil else {
                return nil
            }
            guard let mediaType = EpubMediaTypes.mediaTypeForExtension[url.pathExtension.lowercased()] else {
                return nil
            }
            return( href, itemId, mediaType)
        }
        let sortedMissingResources = missingResources.sorted { lhs, rhs in
            return lhs.itemId < rhs.itemId
        }
        for tuple in sortedMissingResources {
            try DomHelpers.addItem( to:manifest, id:tuple.itemId, href:tuple.href, mediaType:tuple.mediaType)
        }
    }


    func add(mediaOverlays: [MediaOverlay], to document: Document, audioFiles: [AudioFile]) throws {
        
        if !mediaOverlays.isEmpty {
            let overlayDir = mediaOverlays[0].filePath.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: overlayDir)
            try FileManager.default.createDirectory(at: overlayDir, withIntermediateDirectories: true)
        }
        
        guard let manifest = try document.select("manifest").first(),
              let metadata = try document.select("metadata").first() else {
            throw StoryAlignError("Missing manifest or metadata")
        }

        for mo in mediaOverlays {
            guard let item = try manifest.select("item[id=\(mo.manifestItem.id)]").first() else {
                throw StoryAlignError("Missing manifest item for \(mo.manifestItem.id)")
            }
            try item.attr("media-overlay", mo.itemId)
            let meta = try DomHelpers.buildMeta( refines:mo.itemId, property: "media:duration" , text: mo.sentenceRanges.duration.HHMMSSs)
            try metadata.appendChild(meta)
            try mo.overlayXml.write(to: mo.filePath, atomically: true, encoding: .utf8)
        }

        let totalDuration = mediaOverlays.reduce(0.0) { $0 + $1.sentenceRanges.duration }
        
        try metadata.appendChild(DomHelpers.buildMeta(attributes: [("property","media:duration")], text: totalDuration.HHMMSSs))
        try metadata.appendChild(DomHelpers.buildMeta(attributes: [("property","media:active-class")], text: "-epub-media-overlay-active"))
                
        for overlay in mediaOverlays {
            try DomHelpers.addItem(to: manifest, id: overlay.itemId, href: overlay.href, mediaType: "application/smil+xml")
        }
        
        let audioFiles = Array( Set( mediaOverlays.flatMap { $0.audioFiles } ) )
        let sortedAudioFiles = audioFiles.sorted { $0.filePath.path < $1.filePath.path }
        for audioFile in sortedAudioFiles {
            try DomHelpers.addItem(to: manifest, id: audioFile.itemId, href: audioFile.href, mediaType: audioFile.mediaType)
        }
    }

    func addStyles(to document: Document, eBook: EpubDocument) throws {
        guard let manifest = try document.select("manifest").first() else {
            throw StoryAlignError("Manifest not found.")
        }

        try DomHelpers.addItem(to: manifest, id: "storyalignstyles", href: "\(AssetPaths.styles)/storyalign.css", mediaType: "text/css")

        let stylesDirPath = eBook.opfURL.deletingLastPathComponent().appendingPathComponent(AssetPaths.styles)
        let stylesPath = stylesDirPath.appendingPathComponent("storyalign.css")
        try FileManager.default.createDirectory(at: stylesDirPath, withIntermediateDirectories: true)
        try cssStyle.write(to: stylesPath, atomically: true, encoding: .utf8)
    }
}


