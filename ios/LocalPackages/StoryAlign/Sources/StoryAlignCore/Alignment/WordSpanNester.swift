//
//  WordSpanNester.swift
//  StoryAlign
//
//  Created by Rich Waters on 2/11/26.
//

import Foundation
import SwiftSoup

struct WordSpanNester {
    
    func nestWordSpans(in doc: Document, sentencePfx:String, wordPfx:String, maxDepth:Int? = nil ) throws {
        guard let body = try doc.select("body").first() else { return }
        try nestWordSpans(in: body, sentencePfx: sentencePfx, wordPfx: wordPfx, maxDepth: maxDepth)
    }

    private func hasDescendantWithDataSpaceAfterAttr(_ el: Element) throws -> Bool {
        if el.hasAttr(XHTMLTagger.dataSpaceAfterAttrName) { return true }
        return try !el.getElementsByAttribute(XHTMLTagger.dataSpaceAfterAttrName).isEmpty
    }

    private func nestWordSpans(in el: Element, sentencePfx:String, wordPfx:String,  maxDepth:Int?) throws {
        let children = el.getChildNodes()
        var run: [Element] = []
        
        func flushRun() throws {
            guard run.count > 1 else {
                run.removeAll()
                return
            }
            
            var acc = run[0]
            for i in 1..<run.count {
                let next = run[i]
                if acc.parent() == nil || next.parent() == nil {
                    acc = next
                    continue
                }
                try acc.remove()
                if next.childNodeSize() == 0 {
                    try next.appendChild(acc)
                } else {
                    try next.childNode(0).before(acc)
                }
                acc = next
            }

            run.removeAll()
        }
        
        let maxRun = maxDepth

        for n in children {
            guard let el = n as? Element else { continue }

            if try (el.tagName() == "span" &&  el.hasAttr("id") && XHTMLTagger.isWordId(el.attr("id"))) {
                if let maxRun, run.count == maxRun { try flushRun() }
                run.append(el)
                continue
            }

            
            if XHTMLTagger.isSentenceId(try el.attr("id")) {
                try flushRun()
                continue
            }
            
            // Inline tags that contain words and aren't sentences get added to run
            let isInlineTag = HTMLTags.inline.contains(el.tagName().lowercased())
            if isInlineTag {
                if (try el.select("span[id^=\(wordPfx)]").count > 0) {
                    if let maxRun, run.count == maxRun { try flushRun() }
                    run.append(el)
                    continue
                }
                
                // Other inline tags shouldn't break run
                if run.count > 0 /*&& childIndex < (children.count-1) */ {
                    continue
                }
            }
            
            try flushRun()
        }
        
        try flushRun()
        
        // Recurse after folding, using the current child list.
        for n in el.getChildNodes() {
            if let childEl = n as? Element {
                try nestWordSpans(in: childEl, sentencePfx: sentencePfx, wordPfx: wordPfx, maxDepth: maxDepth)
            }
        }
    }
    
    private func prependChild(_ child: Node, to parent: Element) throws {
        if parent.childNodeSize() == 0 {
            try parent.appendChild(child)
            return
        }
        let first = parent.childNode(0)
        try first.before(child)
    }
}


/*
 extension WordSpanNester {
 func deepestNestedSentence(in doc: Document, sentencePfx:String, wordPfx:String ) throws -> (depth:Int, sentence:Element)? {
 guard let longestSentence = try doc.select("span[id^=\(sentencePfx)]").max(by: { lhs, rhs in
 let lhsCount = try lhs.select( "span[id^=\(wordPfx)]" ).count
 let rhsCount = try rhs.select( "span[id^=\(wordPfx)]" ).count
 return lhsCount < rhsCount
 } ) else {
 return nil
 }
 
 let longestDepth = try longestSentence.select( "span[id^=\(wordPfx)]" ).count
 return (depth:longestDepth, sentence:longestSentence)
 }
 }
 */
