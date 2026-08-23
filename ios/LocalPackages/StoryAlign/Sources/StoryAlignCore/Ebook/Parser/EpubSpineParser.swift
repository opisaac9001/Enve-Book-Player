//
// EpubSpineParser.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//


import Foundation

////////////////////////////////////////
// MARK: Spine Parser
//
struct EpubSpineParser {
    func parseSpine(from opfData: Data) throws -> EpubSpine {
        let parser = XMLParser(data: opfData)
        let delegate = SpineParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw NSError(domain: "Spine Parsing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse spine."])
        }
        let spine = EpubSpine(toc: delegate.toc, items: delegate.spineItems )
        return spine
    }
    
    
    class SpineParserDelegate: NSObject, XMLParserDelegate {
        var toc:String = ""
        var spineItems:[EpubSpineItem] = []
        var index:Int = 0
        private var inSpine = false
        
        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String : String] = [:]) {
            
            if elementName == "spine" {
                if let tocID = attributeDict["toc"] {
                    toc = tocID
                }
                inSpine = true
                return
            }
            
            if inSpine && elementName == "itemref" {
                let id = attributeDict["id"]
                guard let idref = attributeDict["idref"] else {
                    return
                }
                let spineItem = EpubSpineItem(idref: idref, id: id, index: index)
                index += 1
                spineItems.append(spineItem)
            }
        }
        
        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "spine" {
                inSpine = false
            }
        }
    }
}
