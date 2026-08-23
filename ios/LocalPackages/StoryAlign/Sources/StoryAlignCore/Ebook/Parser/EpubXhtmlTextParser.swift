//
// EpubXhtmlTextParser.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//



import Foundation

import SwiftSoup
fileprivate let blockBoundarySentinel = "\u{0000}BLOCK_BOUNDARY\u{0000}"


////////////////////////////////////////
// MARK: XHTML Parser
//
struct EpubXhtmlTextParser {
    func parseText(from xmlData:Data) throws -> (String,Bool,Set<String>) {
        return try Self.parseText(from: xmlData)
    }

    static func parseText(from xmlData:Data) throws -> (String,Bool,Set<String>) {
        let parser = XMLParser(data: xmlData)
        let delegate = XmlTextParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw StoryAlignError( "Parsing text from xml failed" )
        }
        return (delegate.extractedText, delegate.hasScript, delegate.resources)
    }
    
    
    class XmlTextParserDelegate: NSObject, XMLParserDelegate {
        var text = String()
        var hasScript:Bool = false
        private var inBody = false
        var resources:Set<String> = []
        
        var extractedText = ""
          
        let blockElements: Set<String> = ["p", "br", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol"]
          
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inBody {
                extractedText += string
            }
        }
        
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
            if elementName == "script" {
                if let src = attributeDict["src"] {
                    resources.insert(src)
                }
                hasScript = true
            }
            if elementName == "link" {
                if let href = attributeDict["href"] {
                    resources.insert(href)
                }
            }
            if elementName == "body" {
                inBody = true
            }
        }
          
        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if blockElements.contains(elementName.lowercased()),
               !extractedText.hasSuffix("\n") {
                extractedText.append("\n")
            }
            if elementName == "body" {
                inBody = false
            }
        }
    }
}

extension EpubXhtmlTextParser {
    static func getXHtmlSentences(from element: Element, granularity:Granularity) throws -> [String] {
        var sentences = [String]()
        var stagedText = ""
        
        let tokenizer = Tokenizer()
        let tokenize = { text in
            if granularity == .phrase {
                return tokenizer.tokenizePhrases(text: text)
            }
            return tokenizer.tokenizeSentences(text: text)
        }
        
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                stagedText += textNode.text()
                continue
            }
            guard let childElem = node as? Element else {
                continue
            }
            let tagName = childElem.tagName()
            
            if HTMLTags.blocks.contains(tagName.lowercased()) {
                sentences += [blockBoundarySentinel]
                sentences += tokenize(stagedText).map { $0 }
                stagedText = ""
                sentences += try getXHtmlSentences(from: childElem, granularity: granularity)
                sentences += [blockBoundarySentinel]
                continue
            }
            stagedText += try getXhtmlTextContent(from:[childElem])
        }
        
        sentences += tokenize(stagedText).map { $0 }
        
        return sentences
    }
    
    static func isMergeableSentence(_ text:String ) -> Bool {
        if text == blockBoundarySentinel {
            return false
        }
        return text.isAllWhiteSpaceOrPunct
    }
    
    static func getXHtmlSentences( from xmlText:String, granularity:Granularity ) throws -> [String] {
        let doc = try SwiftSoup.parse(xmlText)
        guard let body = try doc.select("body").first() else {
            throw StoryAlignError("no <body> found")
        }
        let sentences = try getXHtmlSentences(from: body, granularity: granularity)
        var mergedSentences:[String] = []
        var i = 0
        while i < sentences.count {
            let sentence = sentences[i]
            if sentence == blockBoundarySentinel {
                i += 1
                continue
            }
            
            if i < sentences.count-1 {
                let nextSentence = sentences[i+1]
                if isMergeableSentence(nextSentence) {
                    let nuSentence = sentence + nextSentence
                    mergedSentences.append(nuSentence)
                    i += 2
                    continue
                }
            }
            mergedSentences.append(sentence)
            i += 1
        }
        
        return mergedSentences
    }
    
    static func getXhtmlTextContent(from nodes: [Node]) throws -> String {
        var text = ""
        for node in nodes {
            if let tn = node as? TextNode {
                text += tn.text()
                //text += tn.getWholeText()
            } else if let el = node as? Element {
                text += try getXhtmlTextContent(from: el.getChildNodes())
            }
        }
        return text
    }
}
