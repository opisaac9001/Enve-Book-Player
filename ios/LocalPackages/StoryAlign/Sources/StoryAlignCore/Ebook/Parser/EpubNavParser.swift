//
// EpubNavParser.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//


import Foundation


////////////////////////////////////////
// MARK: Nav Parser
//
struct EpubNavParser {
    func parseNav(from opfURL:URL, opfManifestItems: [OpfManifestItem]) throws -> EpubNav? {
        guard let navItem = EpubOpfResolver.navManifestItem(opfManifestItems) else {
            return nil
        }
        let nav = try parseNav( from:opfURL, navManifestItem: navItem )
        return nav
    }

    func parseNav(from opfURL:URL, navManifestItem:OpfManifestItem) throws -> EpubNav? {
        guard let url = EpubOpfResolver.resolveHref(navManifestItem.href, relativeTo: opfURL) else {
            throw StoryAlignError( "Cannot resolve \(navManifestItem.href) as an href in the OPF.")
        }
        let data = try Data(contentsOf: url)
        return try parseNav(from: data, navManifestItem: navManifestItem)
    }
    

    func parseNav( from navData:Data, navManifestItem:OpfManifestItem) throws -> EpubNav {
        let parser = XMLParser(data: navData)
        let delegate = NavParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw StoryAlignError( "Failed to parse nav." )
        }
        let nav = EpubNav( tocFileHref: navManifestItem.href, landmarks: delegate.landmarks, toc: delegate.tocEntries)
        return nav
    }
    
    class NavParserDelegate: NSObject, XMLParserDelegate {
        var tocEntries: [EpubTocEntry] = []
        var landmarks:[EpubLandmark] = []

        private var inLandmarks = false
        private var inToc = false
        private var foundCharacters = ""
        private var curHref = ""
        
        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String : String] = [:]) {


            if elementName == "nav" && !inLandmarks && !inToc {
                guard let epubtype = attributeDict["epub:type"] else {
                    return
                }
                if epubtype == "landmarks" {
                    inLandmarks = true
                    return
                }
                if epubtype == "toc" {
                    inToc = true
                    return
                }
            }
            if elementName == "a" {
                foundCharacters = ""
                curHref = ""
                
                guard let href = attributeDict["href"] else {
                    return
                }
                
                if inLandmarks {
                    guard let epubtype = attributeDict["epub:type"] else {
                        return
                    }

                    let epubtypeWords = epubtype.split(separator: " ").filter { !$0.isEmpty }
                    for role in epubtypeWords.compactMap({ EpubChapterRole(rawValue: String($0)) }) {
                        landmarks.append(EpubLandmark(href: href, role: role))
                    }
                    return
                }
                if inToc {
                    curHref = href
                }
            }
        }
        
        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "nav" {
                inLandmarks = false
                inToc = false
            }
            if elementName == "a" {
                if curHref.isEmpty {
                    return
                }
                if foundCharacters.trimmed().isEmpty {
                    return
                }
                let tocEntry = EpubTocEntry(href: curHref, title: foundCharacters)
                tocEntries.append(tocEntry)
            }
        }
        
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            foundCharacters += string
        }
    }
}

