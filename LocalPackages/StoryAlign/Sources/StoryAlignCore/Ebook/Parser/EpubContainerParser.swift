//
// EpubContainerParser.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//


import Foundation

////////////////////////////////////////
// MARK: Container Parser
//
struct EpubContainerParser {
    func parseContainer( from containerData: Data ) throws -> EpubContainer {
        let parser = XMLParser(data: containerData)
        let containerDelegate = ContainerXMLParserDelegate()
        parser.delegate = containerDelegate
        guard parser.parse() else {
            throw StoryAlignError( "Failed to parse container" )
        }
        if containerDelegate.container.opfPath.isEmpty {
            throw StoryAlignError( "Missing opfPath in container" )
        }
        return containerDelegate.container
    }
    
    
    class ContainerXMLParserDelegate: NSObject, XMLParserDelegate {
        var container:EpubContainer = EpubContainer()
        
        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String : String] = [:]) {
            if elementName == "rootfile", let fullPath = attributeDict["full-path"] {
                container.opfPath = fullPath
            }
        }
    }
}
