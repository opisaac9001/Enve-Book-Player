//
// Epub2GuideParser.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//


import Foundation

////////////////////////////////////////
// MARK: Guide Parser
//
struct Epub2GuideParser {
    func parseGuide(from opfData: Data) throws -> [EpubGuideItem] {
        let parser = XMLParser(data: opfData)
        let delegate = GuideParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw NSError(domain: "GuideParsing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse guide."])
        }
        return delegate.guideItems
    }
    
    class GuideParserDelegate: NSObject, XMLParserDelegate {
        var guideItems = [EpubGuideItem]()
        private var inGuide = false
        
        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String : String] = [:]) {

            if elementName == "guide" {
                inGuide = true
                return
            }
            if inGuide && elementName == "reference" {
                if let type = attributeDict["type"], let href = attributeDict["href"] {
                    let title = attributeDict["title"]
                    guideItems.append(EpubGuideItem(type: type, title: title, href: href))
                }
            }
        }
        
        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "guide" {
                inGuide = false
            }
        }
    }
}

