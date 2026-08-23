//
// Epub2Adapter.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//


import Foundation
import SwiftSoup

struct Epub2Converter {
    func update( epub:EpubDocument, doc:Document ) throws {
        try updateOpfFromVersion2(in: doc, epub: epub)
        
        let navXhtml = convertTocToNav(from: epub)
        let navPath = epub.opfURL.deletingLastPathComponent().appendingPathComponent(AssetPaths.nav)
        try navXhtml.write(to: navPath, atomically: true, encoding: .utf8)
    }
}

extension Epub2Converter {
    func indent(_ level: Int) -> String { String(repeating: "  ", count: max(0, level)) }

    func updateOpfFromVersion2( in doc:Document, epub:EpubDocument ) throws {
        guard let package = try doc.select("package").first else {
            throw StoryAlignError( "No package in OPF. Cannot update epub2 to epub3 ")
        }
        try package.attr( "version", "3.0")
        
        guard let metadata = try doc.select("metadata").first() else {
            throw StoryAlignError("Metadata not found.")
        }
        
        if let dcFormat = try metadata.getElementsByTag("dc:format").first() {
            if  try dcFormat.text().trimmed().isEmpty {
                try dcFormat.text("application/epub+zip")
            }
        }

        try convertDcIdentifier(in:doc, metadata: metadata)
        try convertDcCreator(in:doc, metadata: metadata)
        try convertDcLanguage(in:doc, metadata: metadata)
        try convertDcDates(in:doc, metadata: metadata)
        try removeEmptyDcTags(in:doc, metadata: metadata)

        if let guide = try doc.select("guide").first() {
            try guide.remove()
        }

        guard let manifest = try doc.select("manifest").first() else {
            throw StoryAlignError("Manifest not found.")
        }

        try DomHelpers.addItem(to: manifest, id:"nav", href: AssetPaths.nav, mediaType: "application/xhtml+xml", properties:"nav")

    }
    
    //func convertTocToNav( from epub:EpubDocument ) -> String {
    func convertTocToNav( from epub:EpubDocument ) -> String {
        let title = (epub.metaInfo.title ?? "").trimmed().escapingXMLEntities()
        let lang = (epub.metaInfo.language ?? "en-US").trimmed().escapingXMLEntities()

        let tocLines = navToc(from: epub, title:title, indentLevel: 2)
        let landmarkLines = navLandmarkLines(from: epub.guide, opfURL: epub.opfURL, navURL: epub.navURL, indentLevel: 2)

        let navXhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops"
              xml:lang="\(lang)" lang="\(lang)">
          <head>
            <title>\(title)</title>
          </head>
          <body>
        \(tocLines.joined(separator: "\n"))

        \(landmarkLines.joined(separator: "\n"))

          </body>
        </html>
        """
        
        return navXhtml
        
    }
    
    
    func navToc( from epub:EpubDocument, title:String, indentLevel:Int=0 ) -> [String] {
        guard let ncx = epub.ncx else {
            return []
        }

        let indent0 = indent(indentLevel)
        let indent1 = indent(indentLevel+1)
        let openingLines = [
            "\(indent0)<nav epub:type=\"toc\" id=\"toc\">",
                "\(indent1)<h1>\(title)</h1>",
        ]
        let closingLines = [
            "\(indent0)</nav>"
        ]
        let ncxURL = epub.ncxURL ?? epub.navURL
        let itemLines = navTocLines(from: ncx.navPoints, ncxURL: ncxURL, navURL:epub.navURL, indentLevel: indentLevel+1)
        if itemLines.isEmpty {
            return []
        }
        return openingLines + itemLines + closingLines
    }

    
    func navTocLines( from navPoints:[NcxNavPoint], ncxURL:URL, navURL:URL, indentLevel:Int=0 ) -> [String] {
        guard !navPoints.isEmpty else {
            return []
        }
        let indent0 = indent(indentLevel)
        let indent1 = indent(indentLevel+1)
        let indent2 = indent(indentLevel+2)

        let openOl = "\(indent0)<ol>"
        let closeOl = "\(indent0)</ol>"
        
        let itemLines = navPoints.flatMap { navPoint in
            let openLi = "\(indent1)<li>"
            let closeLi = "\(indent1)</li>"
            let label = (navPoint.label.isEmpty ? "Untitled" : navPoint.label).escapingXMLEntities()
            
            let resolvedHrefUrl = ncxURL.deletingLastPathComponent().appendingPathComponent(navPoint.src ?? "")
            let href = resolvedHrefUrl.relative(to:navURL)
            let link = href.isEmpty ?  "\(indent2)<span>\(label)</span>" : "\(indent2)<a href=\"\(href)\">\(label)</a>"
            let childrenLines = navPoint.children.isEmpty ? [] : navTocLines(from: navPoint.children, ncxURL: ncxURL, navURL:navURL, indentLevel: indentLevel+3)
            let lines = [openLi] + [link] + childrenLines + [closeLi]
            return lines
        }

        return [openOl] + itemLines + [closeOl]
    }

    func navLandmarkLines(from guide: [EpubGuideItem], opfURL:URL, navURL:URL,  indentLevel: Int = 0) -> [String] {

        func isContentDocHref(_ href: String) -> Bool {
            let h = href.lowercased()
            if h.contains(".xhtml") { return true }
            if h.contains(".html") { return true }
            if h.contains(".htm") { return true }
            if h.contains(".svg") { return true }
            return false
        }

        let typeMap: [String: String] = [
            "toc": "toc",
            "text": "bodymatter",
            "cover": "cover",
            "title-page": "titlepage",
            "copyright": "copyright-page",
            "index": "index",
            "glossary": "glossary",
            "bibliography": "bibliography",
            "acknowledgements": "acknowledgments"
        ]

        let items = guide.compactMap { gi -> (epubType: String, title: String, href: String)? in
            guard isContentDocHref(gi.href) else { return nil }

            let k = gi.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let epubType = typeMap[k] else { return nil }

            let t = (gi.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = t.isEmpty ? gi.type : t

            return (epubType, title, gi.href)
        }

        if items.isEmpty { return [] }

        let indent0 = indent(indentLevel)
        let indent1 = indent(indentLevel+1)
        let indent2 = indent(indentLevel+2)
        let openingLines = [
            "\(indent0)<nav epub:type=\"landmarks\" id=\"landmarks\">",
            "\(indent1)<h2>Landmarks</h2>",
            "\(indent1)<ol>"
        ]

        let itemLines = items.map{ it in
            let resolvedHrefUrl = opfURL.deletingLastPathComponent().appendingPathComponent(it.href)
            let href = resolvedHrefUrl.relative(to:navURL)
            let escHref = href.escapingXMLEntities()
            let escTitle = it.title.escapingXMLEntities()
            let escEpubType = it.epubType.escapingXMLEntities()
            return "\(indent2)<li><a epub:type=\"\(escEpubType)\" href=\"\(escHref)\">\(escTitle)</a></li>"
        }

        let closingLines = [
            "\(indent1)</ol>",
            "\(indent0)</nav>"
        ]

        return openingLines + itemLines + closingLines
    }
}


extension Epub2Converter {
    func convertDcIdentifier( in doc:Document, metadata:Element ) throws {
        guard let dcIdentifier = try metadata.getElementsByTag("dc:identifier").first() else {
            return
        }
        let val = try dcIdentifier.text().trimmed()
        if val.isEmpty {
            try dcIdentifier.remove()
            return
        }

        let scheme = try dcIdentifier.attr("opf:scheme").trimmed()
        
        if try dcIdentifier.attr("id").isEmpty {
            try dcIdentifier.attr("id", "pub-id")
        }
        
        if let package = try doc.select("package").first() {
            try package.attr("unique-identifier", try dcIdentifier.attr("id"))
        }
        
        if !scheme.isEmpty {
            let identifierId = try dcIdentifier.attr("id")
            let refines = try DomHelpers.buildMeta( refines:identifierId, property: "identifier-type", text: scheme)
            try metadata.appendChild(refines)
            try dcIdentifier.removeAttr("opf:scheme")
        }
    }
    
    func convertDcCreator( in doc:Document, metadata:Element ) throws {
        let creators = try metadata.getElementsByTag("dc:creator").array()
        guard !creators.isEmpty else { return }

        try creators.enumerated().forEach { idx, dcCreator in
            let val = try dcCreator.text().trimmed()
            if val.isEmpty {
                try dcCreator.remove()
                return
            }
            
            if try dcCreator.attr("id").isEmpty {
                try dcCreator.attr("id", "creator-\(idx+1)")
            }
            
            let creatorId = try dcCreator.attr("id")
            
            let fileAs = try dcCreator.attr("opf:file-as").trimmed()
            if !fileAs.isEmpty {
                let refines = try DomHelpers.buildMeta(refines: creatorId, property: "file-as", text:fileAs )
                try metadata.appendChild(refines)
                try dcCreator.removeAttr("opf:file-as")
            }
            
            let role = try dcCreator.attr("opf:role").trimmed()
            if !role.isEmpty {
                let refines = try DomHelpers.buildMeta( refines: creatorId, property: "role", scheme: "marc:relators", text: role )
                try metadata.appendChild(refines)
                try dcCreator.removeAttr("opf:role")
            }
        }
    }
    
    func convertDcLanguage( in doc:Document, metadata:Element ) throws {
        guard let dcLanguage = try metadata.getElementsByTag("dc:language").first() else {
            return
        }
        let val = try dcLanguage.text().trimmed()
        if val.isEmpty {
            try dcLanguage.remove()
            return
        }
        try dcLanguage.removeAttr("xsi:type")
    }
    
    func convertDcDates( in doc:Document, metadata:Element ) throws {
        var foundPubDate:Bool = false
        try metadata.getElementsByTag("dc:date").array().enumerated().forEach { idx, dcDate in
            let val = try dcDate.text().trimmed()
            if val.isEmpty || foundPubDate {
                try dcDate.remove()
                return
            }

            let event = try dcDate.attr("opf:event").trimmed()
            if event == "publication" {
                foundPubDate = true
            }
            try dcDate.removeAttr("opf:event")
        }
    }

    func removeEmptyDcTags( in doc:Document, metadata:Element ) throws {
        let children = metadata.children().array()
        try children.forEach { el in
            let tagName = el.tagName().lowercased()
            guard try el.text().trimmed().isEmpty else {
                return
            }
            guard tagName.hasPrefix("dc:") else {
                return
            }
            
            try el.remove()
        }
    }

}

extension Epub2Converter {
    func cleanupNcx( epub:EpubDocument, doc:Document ) throws {
        
        if let ncx = epub.ncx {
            guard let manifest = try doc.select("manifest").first() else {
                throw StoryAlignError("Manifest not found.")
            }
            if let ncxItem = try? manifest.select("item[id=\"\(ncx.ncxId)\"]").first() {
                try? ncxItem.remove()
            }
        }
        
        if let spine = try doc.select("spine").first() {
            try spine.removeAttr("toc")
        }
        
        if let ncxUrl = epub.ncxURL {
            try? FileManager.default.removeItem(at: ncxUrl)
        }
    }

}
