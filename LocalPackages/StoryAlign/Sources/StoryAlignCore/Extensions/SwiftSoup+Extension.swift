//
//  SwiftSoup+Extension.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2009-2025 Jonathan Hedley <https://jsoup.org/>
// Swift port copyright (c) 2016-2025 Nabil Chatbi
// Extension Copyright (c) 2025 Rich Waters
//po 
//

import SwiftSoup

fileprivate let dataSpaceAfterAttrName = XHTMLTagger.dataSpaceAfterAttrName

extension Node {
    private var inlineTags: Set<String> {
        HTMLTags.inline
    }
    private var blockTags:Set<String> {
        HTMLTags.blocks
    }
    
    func xmlFormatted(indentLevel:Int = 0 ) throws -> String {
        return try xmlFormattedNonRecursive(indentLevel: indentLevel)
        //return try xmlFormattedRecursive(indentLevel: indentLevel)
    }
    
    private func xmlFormattedNonRecursive(indentLevel: Int = 0) throws -> String {
        func formatSubtree(_ root: Node, indentLevel: Int) throws -> String {
            enum Mode { case inline, block }

            struct ElementFrame {
                let el: Element
                let indentLevel: Int
                let indent: String
                let openTag: String
                let closeTag: String
                let children: [Node]
                let mode: Mode

                var index: Int
                var bodyStartLen: Int // only used for inline
                var skipLeadingSpaceNext: Bool
                
                var pendingSpace: Bool

            }

            enum Frame {
                case node(Node, Int)
                case element(ElementFrame)
                case postBlockChild(parentOut: StringBuilder, childOut: StringBuilder)
            }

            var out = StringBuilder(256)

            func appendString(_ s: String) {
                if !s.isEmpty { out.append(s) }
            }

            
            func nextMeaningfulIndex(in kids: [Node], after i: Int) -> Int? {
                var j = i + 1
                while j < kids.count {
                    let n = kids[j]
                    if let tn = n as? TextNode {
                        if !tn.getWholeText().trimmed().isEmpty { return j }
                        j += 1
                        continue
                    }
                    if n is Comment { j += 1; continue }
                    return j
                }
                return nil
            }

            func appendIndent(_ level: Int) {
                if level > 0 { out.append(String(repeating: "  ", count: level)) }
            }

            func appendIndentString(_ indent: String) {
                if !indent.isEmpty { out.append(indent) }
            }

            func lastCharIsWhitespace() -> Bool {
                guard out.length > 0 else { return false }
                // We only need this for the exact logic you had: it was checking `body.last!.isWhitespace`.
                // Your output here is overwhelmingly ASCII; treat common ASCII whitespace as whitespace.
                guard let lastByte = out.buffer.last else { return false }
                return lastByte == 0x20 || lastByte == 0x0A || lastByte == 0x09 || lastByte == 0x0D
            }
            
            var stack: [Frame] = [.node(root, indentLevel)]

            while let top = stack.popLast() {
                switch top {
                        
                    case .postBlockChild(let parentOut, let childOut):
                        let rendered = childOut.toString()
                        out = parentOut
                        if !rendered.isEmpty {
                            appendString(cleanLineIfSingleLine(rendered))
                            out.append("\n")
                        }
                        
                case .node(let node, let level):
                    // Match your original indentation behavior
                    let indent = String(repeating: "  ", count: level)

                    if node is DocumentType {
                        appendString("<!DOCTYPE html>")
                        continue
                    }

                    if let el = node as? Element, el.tagName() == "meta" {
                        let httpEquiv = try el.attr("http-equiv").lowercased()
                        let content = try el.attr("content").lowercased()

                        if httpEquiv == "content-type" || content.contains("charset=") || content.contains("text/html") {
                            appendIndentString(indent)
                            appendString("<meta charset=\"utf-8\"/>")
                            continue
                        }
                    }

                    if let el = node as? Element, el.tagName() == "#root" {
                        let header = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"

                        var doctypeParts: [String] = []
                        for child in el.getChildNodes() where child is DocumentType {
                            let s = try formatSubtree(child, indentLevel: 0)
                            if !s.isEmpty { doctypeParts.append(s) }
                        }
                        let doctypeDecls = doctypeParts.joined(separator: "\n")

                        var bodyParts: [String] = []
                        for child in el.getChildNodes() where !(child is DocumentType) {
                            let s = try formatSubtree(child, indentLevel: level)
                            if !s.isEmpty { bodyParts.append(s) }
                        }
                        let body = bodyParts.joined(separator: "\n")

                        let combined = [header, doctypeDecls, body]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")

                        appendString(combined)
                        continue
                    }

                    if let cmt = node as? Comment {
                        let cmtHtml = try cmt.outerHtml()
                        if cmtHtml.trimmed().starts(with: "<!--?xml") {
                            continue
                        }
                        appendIndentString(indent)
                        appendString(cmtHtml)
                        continue
                    }

                    if let dataNode = node as? DataNode {
                        let raw = dataNode.getWholeData()
                        let normalized = try Entities.unescape(raw)
                        let escaped = normalized.escapingXMLEntities()
                        if escaped.trimmed().isEmpty {
                            continue
                        }
                        appendIndentString(indent)
                        appendString(escaped)
                        continue
                    }

                    if let text = node as? TextNode {
                        let raw = text.getWholeText()
                        let normalized = try Entities.unescape(raw)
                        let escaped = normalized.escapingXMLEntities()
                        if escaped.trimmed().isEmpty {
                            continue
                        }
                        appendIndentString(indent)
                        appendString(escaped)
                        continue
                    }

                    guard let el = node as? Element else {
                        continue
                    }

                    let name = el.tagName()
                    let lower = name.lowercased()

                    let attrs = try el.attributesAsNormalizedString()

                        let wrapperDiscardable = el.hasAttr(XHTMLTagger.dataDicardableWrapper)
                        let openTag = wrapperDiscardable ? "" : (attrs.isEmpty ? "<\(name)>" : "<\(name) \(attrs)>")
                        let closeTag = wrapperDiscardable ? "" : "</\(name)>"

                    let meaningfulChildren = el.getChildNodes().filter {
                        if let tn = $0 as? TextNode {
                            return !tn.getWholeText().trimmed().isEmpty
                        }
                        return true
                    }

                    if meaningfulChildren.isEmpty {
                        appendIndentString(indent)
                        if attrs.isEmpty {
                            appendString("<\(name)/>")
                        } else {
                            appendString("<\(name) \(attrs)/>")
                        }
                        continue
                    }

                    let children = el.getChildNodes()

                    let isBlock = blockTags.contains(lower)
                    let hasInlineOnly = children.allSatisfy {
                        if let cEl = $0 as? Element {
                            return inlineTags.contains(cEl.tagName().lowercased())
                        }
                        if let tn = $0 as? TextNode {
                            return !tn.getWholeText().trimmed().isEmpty
                        }
                        return false
                    }

                    let inlineMode = inlineTags.contains(lower) || (!isBlock && hasInlineOnly)
                    if inlineMode {
                        appendIndentString(indent)
                        appendString(openTag)

                        let frame = ElementFrame(
                            el: el,
                            indentLevel: level,
                            indent: indent,
                            openTag: openTag,
                            closeTag: closeTag,
                            children: children,
                            mode: .inline,
                            index: 0,
                            bodyStartLen: out.length,
                            skipLeadingSpaceNext: false,
                            pendingSpace: false
                        )
                        stack.append(.element(frame))
                        continue
                    } else {
                        appendIndentString(indent)
                        appendString(openTag)
                        out.append("\n")

                        let frame = ElementFrame(
                            el: el,
                            indentLevel: level,
                            indent: indent,
                            openTag: openTag,
                            closeTag: closeTag,
                            children: children,
                            mode: .block,
                            index: 0,
                            bodyStartLen: 0,
                            skipLeadingSpaceNext: false,
                            pendingSpace: false
                        )
                        stack.append(.element(frame))
                        continue
                    }

                case .element(var frame):
                    switch frame.mode {
                    case .inline:
                        if frame.index >= frame.children.count {
                            appendString(frame.closeTag)
                            continue
                        }
                            
                            let c = frame.children[frame.index]
                            let i = frame.index

                        frame.index += 1
                            
                            func flushPendingSpace(beforeNext nextTextStartsWithWS: Bool) {
                                guard frame.pendingSpace else { return }
                                frame.pendingSpace = false
                                
                                let alreadyEndsWithWS = lastCharIsWhitespace()
                                let bodyHasContent = out.length > frame.bodyStartLen
                                if bodyHasContent && !alreadyEndsWithWS && !nextTextStartsWithWS {
                                    out.append(" ")
                                    frame.skipLeadingSpaceNext = true
                                }
                            }

                        if let tn = c as? TextNode {
                            let raw = tn.getWholeText()
                            let normalized = try Entities.unescape(raw)
                            let escaped = normalized.escapingXMLEntities()
                            
                            guard !escaped.trimmed().isEmpty else {
                                stack.append(.element(frame))
                                continue
                            }
                            
                            if frame.pendingSpace, escaped.first?.isWhitespace == true {
                                frame.pendingSpace = false
                                frame.skipLeadingSpaceNext = true
                            }
                            
                            flushPendingSpace(beforeNext: escaped.first?.isWhitespace == true)
                            
                                          

                            let bodyHasContent = out.length > frame.bodyStartLen
                            if frame.skipLeadingSpaceNext && bodyHasContent && lastCharIsWhitespace() {
                                let trimmedLeading = String(escaped.drop { $0.isWhitespace })
                                appendString(trimmedLeading)
                            } else {
                                appendString(escaped)
                            }

                            frame.skipLeadingSpaceNext = false

                            stack.append(.element(frame))
                            continue
                        }

                        if let elc = c as? Element {
                            flushPendingSpace(beforeNext: false)
                            
                            if trailingPathRequestsSpaceAfter(elc) {
                                frame.pendingSpace = (nextMeaningfulIndex(in: frame.children, after: i) != nil)
                            } else {
                                frame.pendingSpace = false
                            }
                            
                            stack.append(.element(frame))
                            stack.append(.node(elc, 0))

                            continue
                        }

                        // Other node types are ignored in your original inline loop.
                        stack.append(.element(frame))
                        continue

                    case .block:
                            if frame.index >= frame.children.count {
                                appendIndentString(frame.indent)
                                appendString(frame.closeTag)
                                continue
                            }
                            
                            let c = frame.children[frame.index]
                            frame.index += 1
                            stack.append(.element(frame))
                            let parentOut = out
                            let childOut = StringBuilder(128)
                            out = childOut
                            stack.append(.postBlockChild(parentOut: parentOut, childOut: childOut))
                            stack.append(.node(c, frame.indentLevel + 1))
                            continue
                    }
                }
            }

            return out.toString()
        }

        return try formatSubtree(self, indentLevel: indentLevel)
    }
    
    private func xmlFormattedRecursive(indentLevel: Int = 0) throws -> String {
        let indent = String(repeating: "  ", count: indentLevel)

        if let _ = self as? DocumentType {
            return "<!DOCTYPE html>"
            // This doesn't work when updating epub2
            //return try dt.outerHtml()
        }
        //print( "ELC ObjectIdentifier \(ObjectIdentifier(self)) ID: \((self as? Element)?.id() ?? "nil" )")

        
        // Mostly to fix epub2
        if let el = self as? Element, el.tagName() == "meta"  {
            let httpEquiv = try attr("http-equiv").lowercased()
            let content = try attr("content").lowercased()

            if httpEquiv == "content-type" || content.contains("charset=") || content.contains("text/html") {
                return indent + "<meta charset=\"utf-8\"/>"
            }
        }

        // 1) Strip off the SwiftSoup “#root” wrapper, but add our XML prolog
        if let el = self as? Element, el.tagName() == "#root"  {
            let header = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            
                let nodes = el.getChildNodes()
                var doctypeParts: [String] = []
                var bodyParts: [String] = []
            
                for node in nodes {
                    if node is DocumentType {
                        let s = try node.xmlFormattedRecursive(indentLevel: 0)
                        if !s.isEmpty { doctypeParts.append(s) }
                        continue
                    }
            
                    let s = try node.xmlFormattedRecursive(indentLevel: indentLevel)
                    if !s.isEmpty { bodyParts.append(s) }
                }
            
                let doctypeDecls = doctypeParts.joined(separator: "\n")
                let body = bodyParts.joined(separator: "\n")
             
            /*

            let doctypeDecls = try el.getChildNodes().compactMap { node in
                node is DocumentType
                    ? try node.xmlFormattedRecursive(indentLevel: 0)
                    : nil
            }.joined(separator: "\n")

            let body = try el
                .getChildNodes()
                .filter { !($0 is DocumentType) }
                .map { try $0.xmlFormattedRecursive(indentLevel: indentLevel) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
             */

            return [header, doctypeDecls, body]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        
        
        if let cmt = self as? Comment {
            let cmtHtml = try cmt.outerHtml()
            if cmtHtml.trimmed().starts(with: "<!--?xml") {
                return ""
            }
            return indent + cmtHtml
        }
        
        if let dataNode = self as? DataNode {
            let raw = dataNode.getWholeData()
            let normalized = try Entities.unescape(raw)
            let escaped = normalized.escapingXMLEntities()
            if escaped.trimmed().isEmpty {
                return ""
            }
            return indent + escaped
        }
        
        if let text = self as? TextNode {
            //let t = text.getWholeText()
            //if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
            //return indent + t
            
            let raw = text.getWholeText()
            let normalized = try Entities.unescape(raw)
            let escaped = normalized.escapingXMLEntities()
            guard !escaped.trimmed().isEmpty else { return "" }
            return indent + escaped
        }
        guard let el = self as? Element else {
            return ""
        }
        let name = el.tagName()
        let lower = name.lowercased()
        
        
        let attrs = try el.attributesAsNormalizedString()
        
        let wrapperDiscardable = el.hasAttr(XHTMLTagger.dataDicardableWrapper)
        let openTag = wrapperDiscardable ? "" : attrs.isEmpty
            ? "<\(name)>"
            : "<\(name) \(attrs)>"
        let closeTag = wrapperDiscardable ? "" : "</\(name)>"
        
        let meaningfulChildren = el.getChildNodes().filter {
          if let tn = $0 as? TextNode {
              return !tn.getWholeText().trimmed().isEmpty
          }
          return true
        }
        if meaningfulChildren.isEmpty {
            if wrapperDiscardable {
                return ""
            }
          let slash = attrs.isEmpty ? "/>" : "/>"
          return indent + "<\(name)\(attrs.isEmpty ? "" : " \(attrs)")\(slash)"
        }

        let children = el.getChildNodes()
        let isBlock = blockTags.contains(lower)
        let hasInlineOnly = children.allSatisfy {
            if let el = $0 as? Element {
                return inlineTags.contains(el.tagName().lowercased())
            }
            if let tn = $0 as? TextNode {
                return !tn.getWholeText().trimmed().isEmpty
            }
            return false
        }
        /*
        if inlineTags.contains(lower) || (!isBlock && hasInlineOnly) {
            var body = ""
            for c in children {
                body += try c.xmlFormatted(indentLevel: 0)
            }
            return indent + openTag + body + closeTag
        }
         */
        /*
        if inlineTags.contains(lower) || (!isBlock && hasInlineOnly) {
            var body = ""
            var sawText = false
            var skipLeadingSpaceNext = false

            try children.pairs().forEach { (prev, c) in
                if let tn = c as? TextNode {
                    let raw = tn.getWholeText()
                    let normalized = try Entities.unescape(raw)
                    let escaped = normalized.escapingXMLEntities()
                    if skipLeadingSpaceNext && !body.isEmpty && body.last!.isWhitespace {
                        body += String(escaped.drop { $0.isWhitespace })
                    } else {
                        body += escaped
                    }
                    skipLeadingSpaceNext = false
                    sawText = true
                    return
                }
                if let elc = c as? Element {
                    if sawText && !body.isEmpty /*&& !elc.isEmpty()*/ {
                        /*
                        if let prevElement = prev as? Element {
                            if !skipLeadingSpaceNext {
                                let prevElementsWithSpaceAttr = try prevElement.getElementsByAttribute(XHTMLTagger.dataSpaceAfterAttrName)
                                if !body.last!.isWhitespace && prevElement.hasAttr(XHTMLTagger.dataSpaceAfterAttrName) {
                                    body += " "
                                }
                                else if !prevElementsWithSpaceAttr.isEmpty {
                                    body += " "
                                }
                            }
                            /*
                             if prev?.hasAttr(XHTMLTagger.dataSpaceAfterAttrName) ?? false {
                             body += " "
                             }*/
                        }*/
                    }
                    let elcBody = try elc.xmlFormattedRecursive(indentLevel: 0)
                    body += elcBody
                    if elc.hasAttr(XHTMLTagger.dataSpaceAfterAttrName) {
                        if !elcBody.isEmpty  && !elcBody.last!.isWhitespace && !body.last!.isWhitespace {
                            body += " "
                            skipLeadingSpaceNext = true
                        }
                    }
                    
                    //body += try elc.xmlFormattedRecursive(indentLevel: 0)
                    sawText = true
                }
            }
            return indent + openTag + body + closeTag
        }
         */
        
        if inlineTags.contains(lower) || (!isBlock && hasInlineOnly) {
            var body = ""
            var skipLeadingSpaceNext = false
            var pendingSpace = false

            func flushPendingSpace(beforeNext nextTextStartsWithWS: Bool) {
                guard pendingSpace else { return }
                pendingSpace = false

                // Only insert if it would actually separate tokens.
                let alreadyEndsWithWS = body.last?.isWhitespace == true
                if !alreadyEndsWithWS && !nextTextStartsWithWS && !body.isEmpty {
                    body += " "
                    skipLeadingSpaceNext = true
                }
            }

            // Helper: find whether there is a *next meaningful node* after index i
            func nextMeaningfulIndex(after i: Int) -> Int? {
                let kids = children
                var j = i + 1
                while j < kids.count {
                    let n = kids[j]
                    if let tn = n as? TextNode {
                        if !tn.getWholeText().trimmed().isEmpty { return j }
                        j += 1
                        continue
                    }
                    if n is Comment { j += 1; continue }
                    return j
                }
                return nil
            }

            for (i, c) in children.enumerated() {
                if let tn = c as? TextNode {
                    let raw = tn.getWholeText()
                    let normalized = try Entities.unescape(raw)
                    let escaped = normalized.escapingXMLEntities()
                    guard !escaped.trimmed().isEmpty else { continue }
                    
                    // If the *previous emitted element* already promised a space-after,
                    // don't also emit a leading whitespace from this text node.
                    if pendingSpace, escaped.first?.isWhitespace == true {
                        pendingSpace = false
                        skipLeadingSpaceNext = true
                    }

                    flushPendingSpace(beforeNext: escaped.first?.isWhitespace == true)

                    if skipLeadingSpaceNext && body.last?.isWhitespace == true {
                        body += String(escaped.drop { $0.isWhitespace })
                    } else {
                        body += escaped
                    }
                    skipLeadingSpaceNext = false
                    continue
                }

                if let elc = c as? Element {
                    // If there’s a pending space, we don’t know yet whether we need it;
                    // but for elements, treat "next starts with WS" as false.
                    flushPendingSpace(beforeNext: false)
                    

                    let elcBody = try elc.xmlFormattedRecursive(indentLevel: 0)
                    body += elcBody
                    
                    if trailingPathRequestsSpaceAfter(elc) {
                        pendingSpace = (nextMeaningfulIndex(after: i) != nil)
                    } else {
                        pendingSpace = false
                    }
                    
                    /*
                    //if elc.hasAttr(XHTMLTagger.dataSpaceAfterAttrName) {
                    let elcRequestsSpaceAfter = try ( elc.hasAttr(XHTMLTagger.dataSpaceAfterAttrName) || !elc.getElementsByAttribute(XHTMLTagger.dataSpaceAfterAttrName).isEmpty)
                    if elcRequestsSpaceAfter {
                        //if elc.hasAttr(XHTMLTagger.dataSpaceAfterAttrName) {
                        // Defer. Only insert if there is a next meaningful node.
                        pendingSpace = (nextMeaningfulIndex(after: i) != nil)
                    } else {
                        pendingSpace = false
                    }*/
                }
            }

            // If pendingSpace is still true here, it means the last thing asked for a virtual
            // space but there is no next meaningful node inside this inline-only container.
            // We intentionally drop it to avoid trailing " </span>".
            return indent + openTag + body + closeTag
        }

        var out = indent + openTag + "\n"
        
        for c in children {
            let line = try c.xmlFormattedRecursive(indentLevel: indentLevel+1)
            if line.isEmpty {
                continue
            }
           
            let cleanedLine = {
                if line.contains( "\n" ) {
                    return line
                }
                //if line.starts(with: /\ *<\/[A-Za-z][A-Za-z0-9:-]*>/) {
                //    return line
                //}
      
                let cleanedLine = line.trimmingTrailingWhitespace()
                // spaces right before the final closing tag at EOL
                    .replacing(/\ +(<\/[A-Za-z0-9:_-]+>)$/) { m in String(m.1) }
                
                // spaces between adjacent closing tags anywhere in the line: </a>   </span>  -> </a></span>
                    .replacing(/(<\/[A-Za-z0-9:_-]+>) +(?=<\/[A-Za-z0-9:_-]+>)/) { m in String(m.1) }
                return cleanedLine
            }()
                
            //out += line + "\n"
            out += cleanedLine + "\n"
        }
            
        out += indent + closeTag

        return out
    }
    
    func trailingPathRequestsSpaceAfter(_ el: Element) -> Bool {
        // direct flag always wins
        if el.hasAttr(XHTMLTagger.dataSpaceAfterAttrName) { return true }

        // if el ends with real text, don't “inherit” a descendant’s space-after
        // (otherwise nested containers like word51..word0 will all request it)
        func lastMeaningfulNode(_ parent: Element) -> Node? {
            for n in parent.getChildNodes().reversed() {
                if let tn = n as? TextNode {
                    if !tn.getWholeText().trimmed().isEmpty { return tn }
                    continue
                }
                if n is Comment { continue }
                return n
            }
            return nil
        }

        guard let last = lastMeaningfulNode(el) else { return false }
        if last is TextNode { return false }

        func lastMeaningfulElementChild(_ parent: Element) -> Element? {
            for n in parent.getChildNodes().reversed() {
                if let tn = n as? TextNode {
                    if !tn.getWholeText().trimmed().isEmpty { return nil } // ends in text
                    continue
                }
                if n is Comment { continue }
                return n as? Element
            }
            return nil
        }

        var cur = last as! Element
        while true {
            if cur.hasAttr(XHTMLTagger.dataSpaceAfterAttrName) { return true }
            guard let next = lastMeaningfulElementChild(cur) else { return false }
            cur = next
        }
    }
    
    
    func cleanLineIfSingleLine(_ line: String) -> String {
        if line.contains("\n") { return line }
        let cleanedLine = line.trimmingTrailingWhitespace()
        // spaces right before the final closing tag at EOL
            .replacing(/\ +(<\/[A-Za-z0-9:_-]+>)$/) { m in String(m.1) }
        // spaces between adjacent closing tags anywhere in the line: </a>   </span>  -> </a></span>
            .replacing(/(<\/[A-Za-z0-9:_-]+>) +(?=<\/[A-Za-z0-9:_-]+>)/) { m in String(m.1) }
        return cleanedLine
    }
     
     /*
    func cleanLineIfSingleLine(_ line: String) -> String {
        if line.contains("\n") { return line }

        // Cheap early out: if there are no spaces at all, nothing to do.
        if !line.contains(" ") { return line }

        // 1) Trim trailing whitespace (but we know there are no newlines here)
        var s = line
        if let last = s.last, last.isWhitespace {
            s = s.trimmingCharacters(in: .whitespaces)
        }

        // Another cheap early out: if we don't have the substrings that matter, return.
        // - "> " is needed for the "spaces between closing tags" case
        // - " </" (space before </) is needed for the end-of-line tag case
        if !s.contains("> ") && !s.contains(" </") {
            return s
        }

        // 2) Remove spaces right before the final closing tag at EOL: "   </tag>" -> "</tag>"
        if s.hasSuffix(">") {
            // Find the last '<'
            if let lt = s.lastIndex(of: "<") {
                let next = s.index(after: lt)
                if next < s.endIndex, s[next] == "/" {
                    // Walk backward from lt, deleting spaces immediately before it
                    var i = lt
                    while i > s.startIndex {
                        let prev = s.index(before: i)
                        if s[prev] == " " {
                            i = prev
                            continue
                        }
                        break
                    }
                    if i != lt {
                        s.removeSubrange(i..<lt)
                    }
                }
            }
        }

        // 3) Remove spaces between adjacent closing tags: "</a>   </span>" -> "</a></span>"
        // Specifically: after '>' if there's spaces then next is "</"
        if s.contains("> ") {
            var out = String()
            out.reserveCapacity(s.count)

            var i = s.startIndex
            while i < s.endIndex {
                let ch = s[i]
                out.append(ch)

                if ch == ">" {
                    var j = s.index(after: i)

                    // Count spaces after '>'
                    if j < s.endIndex, s[j] == " " {
                        var k = j
                        while k < s.endIndex, s[k] == " " {
                            k = s.index(after: k)
                        }

                        // If the next non-space is "</", skip the spaces; otherwise keep one run as-is.
                        if k < s.endIndex, s[k] == "<" {
                            let k2 = s.index(after: k)
                            if k2 < s.endIndex, s[k2] == "/" {
                                // skip spaces (do nothing)
                                i = s.index(before: k) // i will be advanced by loop end
                                i = s.index(after: i)  // move to k
                                continue
                            }
                        }

                        // Not adjacent closing tags — keep the spaces we saw
                        out.append(contentsOf: repeatElement(" ", count: s.distance(from: j, to: k)))
                        i = s.index(before: k)
                        i = s.index(after: i)
                        continue
                    }
                }

                i = s.index(after: i)
            }

            s = out
        }

        return s
    }*/
}

extension Element {
    func attributesAsNormalizedString() throws -> String {
        let mediaOverlay = try attr("media-overlay")
        let attributes = (getAttributes()?.asList() ?? [])
        let shouldSort =  (parent()?.tagName() == "manifest" && !mediaOverlay.isEmpty)
        let sortedAttributes = shouldSort ? try sortAttributes(attributes) : attributes
        let tagName = self.tagName().lowercased()
        let attrString = try sortedAttributes.compactMap {
            let val = $0.getValue()
            let key = $0.getKey()
            if key == XHTMLTagger.dataSpaceAfterAttrName || key == XHTMLTagger.dataHoistedSpaceAfterAttrName {
                return nil
            }

            // Epub2 cleanup
            if tagName == "table" {
                if key == "summary"  {
                    return nil
                }
                if key == "border" {
                    if val.trimmed().hasPrefix("0") {
                        return nil
                    }
                }
            }
            if tagName == "tr" || tagName == "td" || tagName == "th" {
                if key == "valign" {
                    return nil
                }
                if key == "align" {
                    return nil
                }
            }
            let normalized = try Entities.unescape(val)
            let escaped = normalized.escapingXMLEntities()
            return "\(key)=\"\(escaped)\""
        }.joined(separator: " ")
        return attrString
    }

    func sortAttributes(_ attributes:[Attribute]) throws -> [Attribute] {
        let origAttrKeysOrder = attributes.map { $0.getKey() }
        let attributesOrder = ["id", "href", "media-type", "media-overlay"]
        
        let compIndex = { (index0:Int?,index1:Int?) -> Bool? in
            if index0 != nil && index1 != nil {
                return index0! < index1!
            }
            if index0 != nil && index1 == nil {
                return true
            }
            if index0 == nil && index1 != nil {
                return false
            }
            return nil
        }

        let sortedAttributes = attributes.sorted( by: {
            let index0 = attributesOrder.firstIndex(of: $0.getKey())
            let index1 = attributesOrder.firstIndex(of: $1.getKey())
            if let comp = compIndex(index0,index1) {
                return comp
            }
            
            let origIndex0 = origAttrKeysOrder.firstIndex(of: $0.getKey())
            let origIndex1 = origAttrKeysOrder.firstIndex(of: $1.getKey())
            if let origComp = compIndex(origIndex0,origIndex1) {
                return origComp
            }
            return $0.getKey() < $1.getKey()
        })
        
        return sortedAttributes
    }
}
