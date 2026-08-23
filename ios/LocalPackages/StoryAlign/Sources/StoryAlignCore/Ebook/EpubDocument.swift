//
//  EpubTocEntry.swift
//  StoryAlign
//
//  Created by Rich Waters on 10/17/25.
//

import Foundation


struct EpubMediaTypes {
    static let xhtmlXml = "application/xhtml+xml"
    static let ncxXml = "application/x-dtbncx+xml"
    
    static let mediaTypeForExtension: [String: String] = [
        "xhtml": xhtmlXml,
        "html": xhtmlXml,
        "htm": xhtmlXml,
        
        "ncx": "application/x-dtbncx+xml",
        "opf": "application/oebps-package+xml",
        
        "css": "text/css",
        "js": "text/javascript",
        
        "svg": "image/svg+xml",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "gif": "image/gif",
        "webp": "image/webp",
        
        "mp3": "audio/mpeg",
        "m4a": "audio/mp4",
        "aac": "audio/aac",
        "oga": "audio/ogg",
        "ogg": "audio/ogg",
        "wav": "audio/wav",
        
        "mp4": "video/mp4",
        "m4v": "video/mp4",
        "webm": "video/webm",
        
        "smil": "application/smil+xml",
        
        "ttf": "font/ttf",
        "otf": "font/otf",
        "woff": "font/woff",
        "woff2": "font/woff2",
        
        "xml": "application/xml"
    ]
}


public struct EpubDocument : Codable, Sendable {
    let opfPath: String
    let opfXmlData: Data
    let metaInfo: EpubMetaInfo
    let unzippedURL: URL
    let guide:[EpubGuideItem]
    public let manifest: [EpubManifestItem]
    let spine:EpubSpine
    let nav:EpubNav?
    let ncx:Epub2Ncx?
    let resources:[URL]

    public var isEpub2:Bool { metaInfo.isEpub2 }
    
    public var opfURL: URL {
        return unzippedURL.appendingPathComponent(opfPath)
    }

    init(opfPath:String, opfXmlData: Data, metaInfo: EpubMetaInfo, unzippedURL: URL, guide: [EpubGuideItem], manifest: [EpubManifestItem], spine: EpubSpine, nav:EpubNav? = nil, ncx:Epub2Ncx? = nil, resources:[URL] ) throws {
        self.opfPath = opfPath
        self.opfXmlData = opfXmlData
        self.metaInfo = metaInfo
        self.unzippedURL = unzippedURL
        self.guide = guide
        self.manifest = manifest
        self.spine = spine
        self.nav = nav
        self.ncx = ncx
        self.resources = resources
    }
    
    public var ncxURL: URL? {
        guard let ncx else {
            return nil
        }
        return opfURL.deletingLastPathComponent().appendingPathComponent(ncx.tocFileHref)
    }
    public var navURL: URL {
        let href = nav?.tocFileHref ?? AssetPaths.nav
        return opfURL.deletingLastPathComponent().appendingPathComponent(href)
    }
}

extension EpubDocument {
    var spineOrderedManifest:[EpubManifestItem] {
        manifest.filter { $0.spineItemIndex >= 0 }
            .sorted { $0.spineItemIndex < $1.spineItemIndex }
    }
}

public struct EpubManifestItem : Codable, Sendable {
    public let id: String
    let href: String
    let mediaType: String?
    let properties: [String]?
    public let spineItemIndex:Int
    let text:String?
    let xmlData:Data?
    let hasScript:Bool?
    let xhtmlSentences:[String]
    public let name:String
    let filePath:URL?

    var startTxt:String {
        String(self.text?.prefix(128) ?? "")
    }
    var endTxt:String {
        String(self.text?.suffix(128) ?? "")
    }
    
    var xmlText:String {
        guard let xmlData else {
            return ""
        }
        return String(data:xmlData, encoding:.utf8) ?? ""
    }
    
    func with(
            id: String? = nil,
            href: String? = nil,
            mediaType: String?? = nil,
            properties: [String]?? = nil,
            spineItemIndex: Int? = nil,
            text: String?? = nil,
            xmlData: Data?? = nil,
            hasScript: Bool?? = nil,
            xhtmlSentences: [String]? = nil,
            name: String? = nil,
            filePath: URL?? = nil
    ) -> Self {
        .init(
            id: id ?? self.id,
            href: href ?? self.href,
            mediaType: mediaType ?? self.mediaType,
            properties: properties ?? self.properties,
            spineItemIndex: spineItemIndex ?? self.spineItemIndex,
            text: text ?? self.text,
            xmlData: xmlData ?? self.xmlData,
            hasScript: hasScript ?? self.hasScript,
            xhtmlSentences: xhtmlSentences ?? self.xhtmlSentences,
            name: name ?? self.name,
            filePath: filePath ?? self.filePath
        )
    }

}

struct EpubGuideItem : Codable {
    let type: String
    let title: String?
    let href: String
}

extension [EpubGuideItem] {
    var itemsByType: [String: [EpubGuideItem]] {
        Dictionary(grouping: self, by: \.type)
    }
}


struct EpubSpine : Codable {
    let toc:String
    let items:[EpubSpineItem]
    private let itemsByIdref: [String: EpubSpineItem]
    
    public init(toc: String, items: [EpubSpineItem]) {
        self.toc = toc
        self.items = items
        self.itemsByIdref = Dictionary(uniqueKeysWithValues: items.map { ($0.idref, $0) })
    }

    func contains( manifestItemId:String ) -> Bool {
        return itemsByIdref[manifestItemId] != nil
    }

    public func item(forIdRef idref: String) -> EpubSpineItem? {
        itemsByIdref[idref]
    }
    
    public func index(forIdRef idref: String) -> Int? {
        itemsByIdref[idref]?.index
    }
}

struct EpubSpineItem : Codable {
    let idref:String
    let id:String?
    let index:Int
}

struct EpubMetaInfo : Codable {
    var title: String?
    var creator: String?
    var language: String?
    var identifier: String?
    var date:String?
    var publisher:String?
    var subject:String?
    var version:String?
    
    var isEpub2:Bool {
        guard let version else { return false }
        let v = version.trimmed()
        return v.hasPrefix("2.")
    }
}

struct EpubContainer {
    var opfPath: String = ""
}


struct EpubTocEntry:Codable {
    let href:String
    let title:String
}

struct EpubLandmark : Codable, Sendable {
    let href:String
    let role:EpubChapterRole
}
extension [EpubLandmark] {
    var bodymatterHrefs:[String] {
        self.filter { $0.role == .bodymatter}.map { $0.href }
    }
    var backmatterHrefs:[String] {
        self.filter { $0.role == .backmatter}.map { $0.href }
    }
    func roles(for href:String) -> [EpubChapterRole] {
        return self.filter { $0.href == href }.map { $0.role }
    }
}


protocol EpubNavOrNcx {
    var toc:[EpubTocEntry] { get }
    var tocFileHref:String { get }
    var tocDict:[String:String] { get }
    var landmarks:[EpubLandmark] { get }
}

extension EpubNavOrNcx {

    func title( for itemHref: String ) -> String? {
        if let name = tocDict[itemHref] {
            return name
        }
        if itemHref.deletingLastPathComponent() == self.tocFileHref.deletingLastPathComponent() {
            let itemLast = itemHref.lastPathComponent()
            if let name = tocDict[itemLast] {
                return name
            }
            if let name = tocDict[itemLast.removingFragment()] {
                return name
            }
        }
        return nil
    }
    
    func role(for itemHref:String ) -> EpubChapterRole? {
        return landmarks.roles(for: itemHref).first
    }
    
    static func buildTocDict( toc:[EpubTocEntry]) -> [String:String] {
        return toc.reduce(into: [:]) { result, entry in
            result[entry.href] = entry.title
            let fraglessHref = entry.href.removingFragment()
            guard fraglessHref != entry.href else {
                return
            }
            guard result[fraglessHref] == nil else {
                return
            }
            result[fraglessHref] = entry.title
        }
    }
}

struct EpubNav : EpubNavOrNcx, Codable, Sendable {
    let tocFileHref:String
    let landmarks: [EpubLandmark]
    let toc:[EpubTocEntry]
    let tocDict:[String:String]
    
    init(tocFileHref: String, landmarks:[EpubLandmark], toc: [EpubTocEntry] ) {
        self.tocFileHref = tocFileHref
        self.landmarks = landmarks
        self.toc = toc
        self.tocDict = Self.buildTocDict(toc: toc)
    }
}


public struct Epub2Ncx : EpubNavOrNcx, Codable, Sendable {
    let docTitle: String
    let navPoints: [NcxNavPoint]
    let tocFileHref: String
    let ncxId: String
    let toc:[EpubTocEntry]
    let tocDict: [String : String]
    var landmarks: [EpubLandmark] { [] }

    init(docTitle: String, navPoints: [NcxNavPoint], tocFileHref: String, ncxId: String ) {
        self.docTitle = docTitle
        self.navPoints = navPoints
        self.tocFileHref = tocFileHref
        self.ncxId = ncxId
        
        self.toc =  navPoints.compactMap { navPoint in
            guard let src = navPoint.src else { return nil }
            return EpubTocEntry(href: src , title: navPoint.label)
        }
        self.tocDict = Self.buildTocDict(toc: toc)
    }
}

public struct NcxNavPoint : Codable, Sendable {
    public var label: String
    public var src: String?
    public var children: [NcxNavPoint]
    public init(label: String = "", src: String? = nil, children: [NcxNavPoint] = []) {
        self.label = label
        self.src = src
        self.children = children
    }
}

public enum EpubChapterRole : String, CaseIterable, Codable, Sendable {
    case frontmatter
    case bodymatter
    case backmatter
    case cover
    case titlepage
    case copyrightpage = "copyright-page"
    case toc
    case unlisted // Not found in nav.xhtml, but in spine
}

public struct EpubChapterEntry:Equatable {
    public let manifestId: String
    public let navLabel: String
    public let spineItemIndex: Int
    public let role:EpubChapterRole?
}
