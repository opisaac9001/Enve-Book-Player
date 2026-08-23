//
// EpubNcxParser.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//


import Foundation


////////////////////////////////////////
// MARK: NCX Parser
//
struct EpubNcxParser {
    func parseNcx(from opfURL:URL, opfManifestItems: [OpfManifestItem], spine:EpubSpine) throws -> Epub2Ncx? {
        guard let ncxItem = EpubOpfResolver.ncxManifestItem(opfManifestItems, spine: spine) else {
            return nil
        }
        let ncx = try parseNcx( from:opfURL, ncxManifestItem: ncxItem )
        return ncx
    }

    func parseNcx(from opfURL:URL, ncxManifestItem:OpfManifestItem) throws -> Epub2Ncx {
        guard let ncxUrl = EpubOpfResolver.resolveHref(ncxManifestItem.href, relativeTo: opfURL) else {
            throw StoryAlignError( "Cannot resolve \(ncxManifestItem.href) in \(opfURL.path)." )
        }
        let navData = try Data(contentsOf: ncxUrl)
        return try parseNcx(from: navData, ncxManifestItem: ncxManifestItem)
    }
    
    func parseNcx(from navData:Data, ncxManifestItem:OpfManifestItem) throws -> Epub2Ncx {
        let parser = XMLParser(data: navData)
        let delegate = NcxParseDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw StoryAlignError( "Failed to parse ncx." )
        }
        return Epub2Ncx( docTitle: delegate.docTitle, navPoints: delegate.navPoints, tocFileHref: ncxManifestItem.href, ncxId: ncxManifestItem.id )
    }

    
    class NcxParseDelegate: NSObject, XMLParserDelegate {
        var navPoints: [NcxNavPoint] = []
        var docTitle:String = ""

        private var textBuf = ""
        private var inDocTitle = false
        private var inNavLabel = false
        private var inText = false
        private var stack: [NcxNavPoint] = []
        private func localName(_ raw: String) -> String {
            if let i = raw.lastIndex(of: ":") { return String(raw[raw.index(after: i)...]) }
            return raw
        }
        
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            let n = localName(qName ?? elementName)
            textBuf = ""
            
            if n == "navPoint" {
                stack.append(NcxNavPoint())
                return
            }
            
            if n == "docTitle" {
                inDocTitle = true
                return
            }
            
            if n == "navLabel" {
                inNavLabel = true
                return
            }
            
            if n == "text" {
                inText = true
                return
            }
            
            if n == "content" {
                guard var cur = stack.popLast() else { return }
                cur.src = attributeDict["src"]
                stack.append(cur)
                return
            }
        }
        
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { textBuf += string }
        }
        
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let n = localName(qName ?? elementName)
            
            if n == "text" {
                let t = textBuf.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    if inDocTitle {
                        if docTitle.isEmpty { docTitle = t }
                    } else if inNavLabel {
                        if var cur = stack.popLast() {
                            if cur.label.isEmpty { cur.label = t }
                            stack.append(cur)
                        }
                    }
                }
                inText = false
                textBuf = ""
                return
            }
            
            if n == "navLabel" {
                inNavLabel = false
                return
            }
            
            if n == "docTitle" {
                inDocTitle = false
                return
            }
            
            if n == "navPoint" {
                guard let finished = stack.popLast() else { return }
                if stack.isEmpty {
                    navPoints.append(finished)
                    return
                }
                var parent = stack.removeLast()
                parent.children.append(finished)
                stack.append(parent)
                return
            }
        }
    }
}
