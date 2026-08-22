//
// OpfManifestItem.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//


import Foundation

////////////////////////////////////////
// MARK: Manifest Parser
//
struct OpfManifestItem {
    let id:String
    let href: String
    let mediaType: String?
    let properties: [String]?
}


struct EpubOpfManifestParser {
    func parseManifest(from opfData: Data) throws -> [OpfManifestItem] {
        let parser = XMLParser(data: opfData)
        let delegate = ManifestParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw NSError(domain: "ManifestParsing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse manifest."])
        }
        return delegate.manifestItems
    }
    
    
    class ManifestParserDelegate: NSObject, XMLParserDelegate {
        var manifestItems = [OpfManifestItem]()
        private var inManifest = false
        
        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String : String] = [:]) {
            
            if elementName == "manifest" {
                inManifest = true
                return
            }
            
            if inManifest && elementName == "item" {
                if let id = attributeDict["id"], let href = attributeDict["href"] {
                    let mediaType = attributeDict["media-type"]
                    let props = attributeDict["properties"]?.split(separator: " ").map { String($0) }
                    manifestItems.append(OpfManifestItem(id: id, href: href, mediaType: mediaType, properties: props))
                }
            }
        }
        
        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "manifest" {
                inManifest = false
            }
        }
    }
}
