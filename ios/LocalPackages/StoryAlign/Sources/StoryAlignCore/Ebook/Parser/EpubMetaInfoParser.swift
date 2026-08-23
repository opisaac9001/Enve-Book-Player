//
// EpubMetaInfoParser.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//


import Foundation


////////////////////////////////////////
// MARK: Meta Info Parser
//
struct EpubMetaInfoParser {
    func parseMetaInfo(from opfData:Data) throws -> EpubMetaInfo {
        let parser = XMLParser(data: opfData)
        let delegate = OPFMetaInfoParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            if let err = delegate.error {
                throw err
            }
            throw NSError(domain: "MetaInfoParsing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse meta info."])
        }
        return delegate.metaInfo
    }
    
    class OPFMetaInfoParserDelegate: NSObject, XMLParserDelegate {
        var metaInfo:EpubMetaInfo = EpubMetaInfo()
        var error: Error? = nil
        
        private var currentElement = ""
        private var foundCharacters = ""
        
        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String : String] = [:]) {
            currentElement = elementName
            foundCharacters = ""
            
            if elementName.lowercased() == "package" {
                metaInfo.version = attributeDict["version"]
            }
            if elementName == "dc:contributor" {
                if let id = attributeDict["id"] {
                    if id.starts(with: "storyalign-contributor") {
                        error = StoryAlignError( "It looks as those this epub has already been aligned by storyalign. Please use a different epub file." )
                        parser.abortParsing()
                        return
                    }
                }
            }
            if elementName == "meta" {
                if let property = attributeDict["property"] {
                    if property.lowercased() == "storyteller:media-overlays-modified" {
                        error = StoryAlignError( "It looks as those this epub has already been aligned by storyteller-platform. Please use a different epub file." )
                        parser.abortParsing()
                    }
                }
            }
        }
        
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            foundCharacters += string
        }
        
        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let trimmed = foundCharacters.trimmed()
            switch elementName {
                case "dc:identifier":
                    metaInfo.identifier = trimmed
                case "dc:title":
                    metaInfo.title = trimmed
                case "dc:creator":
                    metaInfo.creator = trimmed
                case "dc:language":
                    metaInfo.language = trimmed
                case "dc:publisher":
                    metaInfo.publisher = trimmed
                case "dc:date":
                    metaInfo.date = trimmed
                case "dc:subject":
                    metaInfo.subject = trimmed
                default:
                    break
            }
        }
    }
}
