//
// XHTMLTagger.swift
//
// SPDX-License-Identifier: MIT
//
// Original source Copyright (c) 2023 Shane Friedman
// Translated and modified Copyright (c) 2025 Rich Waters
//


import SwiftSoup

struct XHTMLTagger : AlignmentSessionProviding {
    let session: AlignmentSession
    
    static let dataSpaceAfterAttrName = "data-storyalign-space-after"
    static let dataHoistedSpaceAfterAttrName = "data-storyalign-hoisted-space-after"
    static let dataDicardableWrapper = "data-storyalign-discardable-wrapper"

    static let sentenceTagPfx = "sentence"
    static let wordTagPfx = "word"
        
    private func lastLeafElement(in el: Element) -> Element {
        func lastMeaningfulElementChild(_ parent: Element) -> Element? {
            for n in parent.getChildNodes().reversed() {
                if let e = n as? Element { return e }
                if let tn = n as? TextNode {
                    // If the last meaningful thing is real text, stop descending.
                    if !tn.getWholeText().trimmed().isEmpty { return nil }
                    continue
                }
                if n is Comment { continue }
            }
            return nil
        }
        
        var cur = el
        while let last = lastMeaningfulElementChild(cur) {
            cur = last
        }
        return cur
    }

    private func consumeOneExpectedWhitespaceIfPresent(
        sentences: [String],
        state: inout TagState
    ) {
        guard state.currentSentenceIndex < sentences.count else { return }
        let s = sentences[state.currentSentenceIndex]
        guard state.currentSentenceProgress < s.count else { return }
        
        let i = s.index(s.startIndex, offsetBy: state.currentSentenceProgress)
        guard s[i].isWhitespace else { return }
        
        // Treat virtual "space-after" as satisfying one whitespace in the sentence.
        state.currentSentenceProgress += 1
    }
    
    
    private func hoistTrailingSpaceAfterToSentenceSpan(chapterId: String, sentenceId: Int, taggedXml: Element) throws {
        let sid = "\(chapterId)\(sentenceId)"
        guard let span = try taggedXml.getChildNodes().reversed().compactMap({ $0 as? Element }).first(where: { try $0.attr("id") == sid }) else {
            return
        }
        let leaf = lastLeafElement(in: span)

        
        let leafAndAncestors = {
            if leaf == span {
                return [leaf]
            }
            var leafAncestors = [] as [Element]
            var leafAncestorUnderSpan = leaf
            while let p = leafAncestorUnderSpan.parent(), p != span {
                leafAncestorUnderSpan = p
                leafAncestors.append(p)
            }
        
            let spanChildren = span.children()
            if spanChildren.count > 1 {
                let childIndex = spanChildren.firstIndex(of: leafAncestorUnderSpan)
                if childIndex == nil || childIndex! != spanChildren.count - 1 {
                    return [leaf]
                }
            }
            return [leaf] + leafAncestors
        }()
        
        try leafAndAncestors.forEach { leaf in
            guard leaf.hasAttr(Self.dataSpaceAfterAttrName) else {
                return
            }
            guard !span.hasAttr(Self.dataSpaceAfterAttrName) else {
                try leaf.removeAttr(Self.dataSpaceAfterAttrName)
                try leaf.attr(Self.dataHoistedSpaceAfterAttrName, "1")
                return
            }
            try span.attr(Self.dataSpaceAfterAttrName, "1")
            try leaf.removeAttr(Self.dataSpaceAfterAttrName)
            try leaf.attr(Self.dataHoistedSpaceAfterAttrName, "1")
        }
    }
    
    private func finishSentenceIfComplete(
        chapterId: String,
        sentences: [String],
        taggedXml: Element,
        state: inout TagState
    ) throws {
        guard state.currentSentenceIndex < sentences.count else { return }
        let s = sentences[state.currentSentenceIndex]
        guard state.currentSentenceProgress >= s.count else { return }
        
        try hoistTrailingSpaceAfterToSentenceSpan(
            chapterId: chapterId,
            sentenceId: state.currentSentenceIndex,
            taggedXml: taggedXml
        )
        state.currentSentenceIndex += 1
        state.currentSentenceProgress = 0
        resetOpenEmission(&state)
    }
    
    private func markSpaceAfter(in parent: Element) throws {

        func doAddSpaceAttr(el:Element) throws {
            guard !el.hasAttr(Self.dataHoistedSpaceAfterAttrName) else {
                return
            }
            guard !el.hasAttr(Self.dataSpaceAfterAttrName) else {
                return
            }
            try el.attr(Self.dataSpaceAfterAttrName, "1")
        }
        try doAddSpaceAttr(el: parent)
    }
     

    func isXmlTextNode(_ node: Node) -> Bool {
        node is TextNode
    }

    private func resetOpenEmission(_ state: inout TagState) {
        state.openSentenceOwner = nil
        state.openSentenceId = nil
        state.openSentenceSpan = nil
        state.openMarkSigs.removeAll(keepingCapacity: true)
        state.openMarkElems.removeAll(keepingCapacity: true)
    }
    
    private func markSig(_ m: Mark) -> String {
        var s = m.elementName
        for a in m.attributes.asList() {
            s.append("|")
            s.append(a.getKey())
            s.append("=")
            s.append(a.getValue())
        }
        return s
    }
    
    private func ensureSentenceSpan(
            chapterId: String,
            sentenceId: Int,
            in xml: Element,
            state: inout TagState
        ) throws -> Element {
            let owner = ObjectIdentifier(xml)
            if state.openSentenceOwner != owner || state.openSentenceId != sentenceId || state.openSentenceSpan == nil {
                let tagId = "\(chapterId)\(sentenceId)"
                let span = Element(Tag("span"), "")
                try span.attr("id", tagId)
                try xml.appendChild(span)
                
                state.openSentenceOwner = owner
                state.openSentenceId = sentenceId
                state.openSentenceSpan = span
                state.openMarkSigs.removeAll(keepingCapacity: true)
                state.openMarkElems.removeAll(keepingCapacity: true)
            }
            return state.openSentenceSpan!
        }
    
        private func syncMarks(
            _ marks: [Mark],
            into root: Element,
            state: inout TagState
        ) throws -> Element {
            let targetSigs = marks.map(markSig)
            
            var common = 0
            while common < state.openMarkSigs.count, common < targetSigs.count {
                if state.openMarkSigs[common] != targetSigs[common] { break }
                common += 1
            }
            
            while state.openMarkSigs.count > common {
                _ = state.openMarkSigs.popLast()
                _ = state.openMarkElems.popLast()
            }
            
            var parent: Element = state.openMarkElems.last ?? root
            if common < marks.count {
                for i in common..<marks.count {
                    let m = marks[i]
                    let w = Element(Tag(m.elementName), "")
                    for a in m.attributes.asList() {
                        try w.attr(a.getKey(), a.getValue())
                    }
                    try parent.appendChild(w)
                    parent = w
                    state.openMarkSigs.append(targetSigs[i])
                    state.openMarkElems.append(w)
                }
            }
            return parent
        }

    func appendTextNode(
        chapterId: String,
        xml: Element,
        text: String,
        marks: [Mark],
        state: inout TagState,
        taggedSentences: inout Set<Int>,
        sentenceId: Int? = nil
    ) throws {
        guard !text.isEmpty else { return }
        let textNode = TextNode(text, "")
        try appendLeafNode(
            chapterId: chapterId,
            xml: xml,
            node: textNode,
            marks: marks,
            state: &state,
            taggedSentences: &taggedSentences,
            sentenceId: sentenceId
        )
    }

    func appendLeafNode(
        chapterId: String,
        xml: Element,
        node: Node,
        marks: [Mark],
        state: inout TagState,
        taggedSentences: inout Set<Int>,
        sentenceId: Int? = nil
    ) throws {
        // Detect any true leaf element (no children) and clone it
        let isLeafElement: Bool = {
            if let el = node as? Element {
                return el.getChildNodes().isEmpty
            }
            return false
        }()
        
        let nodeToAppend: Node = try  {
            guard isLeafElement, let el = node as? Element else {
                return node
            }
            let orphan = Element(Tag(el.tagName()), "")
            for attr in (el.getAttributes() ?? Attributes()).asList() {
                try orphan.attr(attr.getKey(), attr.getValue())
            }
            return el.copy(clone: orphan)
        }()
        
        // Skip pure-whitespace for everything except those cloned leaf elements
        if !isLeafElement {
            if let tn = nodeToAppend as? TextNode {
                if tn.getWholeText().trimmed().isEmpty {
                    if !tn.getWholeText().isEmpty {
                        //try markSpaceAfter(in: xml)
                        try markSpaceAfter(in: state.openMarkElems.last ?? xml)
                    }
                    return
                }
            } else if let el = nodeToAppend as? Element {
                if try el.text().trimmed().isEmpty { return }
            }
        }
        
        if sentenceId == nil {
            resetOpenEmission(&state)
            let parent = try syncMarks(marks, into: xml, state: &state)
            // Keep marks open across siblings under the same output parent,
            // otherwise inline wrappers like <span id="...-word8"> get duplicated
            // when one sibling is text and the next is <br>.
            /*
            let owner = ObjectIdentifier(xml)
            if state.openSentenceOwner != owner {
                resetOpenEmission(&state)
                state.openSentenceOwner = owner
            }
            let parent = try syncMarks(marks, into: xml, state: &state)
             */
            try parent.appendChild(nodeToAppend)
            return
        }
        
        let root = try ensureSentenceSpan(chapterId: chapterId, sentenceId: sentenceId!, in: xml, state: &state)
        taggedSentences.insert(sentenceId!)
        let parent = try syncMarks(marks, into: root, state: &state)
        try parent.appendChild(nodeToAppend)
    }
    

    @discardableResult
    func tagSentencesInXml(
        chapterId: String,
        state: TagState,
        sentences: [String],
        currentNode: Node,
        taggedSentences: inout Set<Int>,
        marks: [Mark],
        taggedXml: Element
    ) throws -> TagState {
        var state = state
        
        if isXmlTextNode(currentNode), let textNode = currentNode as? TextNode {
            let sentence = sentences[state.currentSentenceIndex]
            
                        if state.currentSentenceProgress >= sentence.count {
                            try hoistTrailingSpaceAfterToSentenceSpan(
                                chapterId: chapterId,
                                sentenceId: state.currentSentenceIndex,
                                taggedXml: taggedXml
                            )
                            state.currentSentenceIndex += 1
                            state.currentSentenceProgress = 0
                            resetOpenEmission(&state)
                            return state
                        }

            let fullText = textNode.text()
            let nodeStart = fullText.index(fullText.startIndex, offsetBy: state.currentNodeProgress)
            let remainingNodeText = String(fullText[nodeStart...])
            // If the next expected sentence characters are whitespace but the DOM text doesn't start with whitespace,
            // consume the sentence whitespace virtually. Otherwise range(of:) will fail and we orphan-emit.
            while state.currentSentenceIndex < sentences.count,
                  state.currentSentenceProgress < sentence.count,
                  !remainingNodeText.isEmpty {
                let i = sentence.index(sentence.startIndex, offsetBy: state.currentSentenceProgress)
                if !sentence[i].isWhitespace { break }
                if remainingNodeText.first?.isWhitespace == true { break }
                state.currentSentenceProgress += 1
            }

            let remStart = sentence.index(sentence.startIndex, offsetBy: state.currentSentenceProgress)
            let remainingSentence = String(sentence[remStart...])

            if remainingSentence.isEmpty {
                try finishSentenceIfComplete(chapterId: chapterId, sentences: sentences, taggedXml: taggedXml, state: &state)
                return state
            }

            let range:Range<String.Index>? = {
                guard let firstChar = remainingSentence.first else {
                    return nil
                }
                let range = remainingNodeText.range(of: String(firstChar))
                return range
            }()
             guard let range else {
                try appendTextNode(
                    chapterId: chapterId,
                    xml: taggedXml,
                    text: remainingNodeText,
                    marks: marks,
                    state: &state,
                    taggedSentences: &taggedSentences
                )
                 state.currentNodeProgress = -1
                 return state
            }
            let idx = remainingNodeText.distance(from: remainingNodeText.startIndex, to: range.lowerBound)

            let charsLeft = remainingNodeText.count - idx

            if charsLeft < remainingSentence.count {
                try appendTextNode(
                    chapterId: chapterId,
                    xml: taggedXml,
                    text: String(remainingNodeText.prefix(idx)),
                    marks: marks,
                    state: &state,
                    taggedSentences: &taggedSentences
                )
                try appendTextNode(
                    chapterId: chapterId,
                    xml: taggedXml,
                    text: String(remainingNodeText.suffix(charsLeft)),
                    marks: marks,
                    state: &state,
                    taggedSentences: &taggedSentences,
                    sentenceId: state.currentSentenceIndex
                )
                
                // If the only remaining part of the sentence is whitespace that
                // does not exist in the DOM/TextNode, consume it virtually and
                // complete the sentence here (so hoist runs).
                let afterDomProgress = state.currentSentenceProgress + charsLeft
                if afterDomProgress < sentence.count && state.currentSentenceIndex == sentences.count - 1 {
                    let i = sentence.index(sentence.startIndex, offsetBy: afterDomProgress)
                    let tail = sentence[i...]
                    if tail.allSatisfy({ $0.isWhitespace }) {
                        //try markSpaceAfter(in: taggedXml)
                        try hoistTrailingSpaceAfterToSentenceSpan(
                            chapterId: chapterId,
                            sentenceId: state.currentSentenceIndex,
                            taggedXml: taggedXml
                        )
                        state.currentSentenceIndex += 1
                        state.currentSentenceProgress = 0
                        state.currentNodeProgress = -1
                        resetOpenEmission(&state)
                        return state
                    }
                }
                
                state.currentSentenceProgress += charsLeft
                state.currentNodeProgress = -1
                return state

            } else {
                try appendTextNode(
                    chapterId: chapterId,
                    xml: taggedXml,
                    text: String(remainingNodeText.prefix(idx)),
                    marks: marks,
                    state: &state,
                    taggedSentences: &taggedSentences
                )
                try appendTextNode(
                    chapterId: chapterId,
                    xml: taggedXml,
                    text: remainingSentence,
                    marks: marks,
                    state: &state,
                    taggedSentences: &taggedSentences,
                    sentenceId: state.currentSentenceIndex
                )
                if state.currentSentenceIndex + 1 == sentences.count {
                    let trailIdx = idx + remainingSentence.count
                    let trailStart = remainingNodeText.index(remainingNodeText.startIndex, offsetBy: trailIdx)
                    let trailing = String(remainingNodeText[trailStart...])
                    try appendTextNode(
                        chapterId: chapterId,
                        xml: taggedXml,
                        text: trailing,
                        marks: marks,
                        state: &state,
                        taggedSentences: &taggedSentences
                    )
                }
                try hoistTrailingSpaceAfterToSentenceSpan(
                    chapterId: chapterId,
                    sentenceId: state.currentSentenceIndex,
                    taggedXml: taggedXml
                )
                let newPos = state.currentNodeProgress + idx + remainingSentence.count
                state.currentSentenceIndex += 1
                state.currentSentenceProgress = 0
                state.currentNodeProgress = newPos
                resetOpenEmission(&state)
                return state
            }
        }

        guard let elem = currentNode as? Element else {
            state.currentNodeProgress = -1
            return state
        }

        for child in elem.getChildNodes() {
            if state.currentSentenceIndex > sentences.count - 1 {
                // orphan-copy branch once we're past all sentences

                // drop pure-whitespace
                if let tn = child as? TextNode {
                    if tn.getWholeText().trimmed().isEmpty {
                        if !tn.getWholeText().isEmpty {
                            //try markSpaceAfter(in: taggedXml)
                            try markSpaceAfter(in: state.openMarkElems.last ?? taggedXml )
                        }
                        continue
                    }
                }

                let orphan: Node
                if let childElem = child as? Element {
                    orphan = Element(Tag(childElem.tagName()), "")
                } else if let text = child as? TextNode {
                    orphan = TextNode(text.text(), "")
                } else {
                    orphan = child
                }
                let childCopy = child.copy(clone: orphan)
                try taggedXml.appendChild(childCopy)
                continue
            }
            state.currentNodeProgress = 0
            let nextTaggedXml = taggedXml
            let nextMarks = marks

            if !isXmlTextNode(child), let childElem = child as? Element {
                let name           = childElem.tagName()
                let lower          = name.lowercased()
                let isBlock        = HTMLTags.blocks.contains(lower)
                let isNonTextLeafForMatching = try (lower == "img" && childElem.hasAttr("alt") && !childElem.attr("alt").trimmed().isEmpty)

                if childElem.getChildNodes().isEmpty {
                    //let sentenceId = (isBlock || state.currentSentenceProgress == 0 || (!hasText && taggedSentences.isEmpty)) ? nil : state.currentSentenceIndex
                    //let sentenceId = (isBlock || state.currentSentenceProgress == 0 || (!hasTextForMatching && taggedSentences.isEmpty)) ? nil : state.currentSentenceIndex
                    let hasText = ((try? !childElem.text().trimmed().isEmpty) == true)
                    let sentenceId = (isBlock || isNonTextLeafForMatching || state.currentSentenceProgress == 0 || (!hasText && taggedSentences.isEmpty)) ? nil : state.currentSentenceIndex

                    try appendLeafNode(
                        chapterId: chapterId,
                        xml: taggedXml,
                        node: childElem,
                        marks: marks,
                        state: &state,
                        taggedSentences: &taggedSentences,
                        sentenceId: sentenceId
                    )
                    
                    // if the SOURCE node had a virtual space-after, consume it
                    if childElem.hasAttr(Self.dataSpaceAfterAttrName) {
                        consumeOneExpectedWhitespaceIfPresent(sentences: sentences, state: &state)
                                            try finishSentenceIfComplete(
                                                chapterId: chapterId,
                                                sentences: sentences,
                                                taggedXml: taggedXml,
                                                state: &state
                                            )
                    }
                    continue
                }

                if isBlock {
                    let wrapper = Element(Tag(name), "")
                    for attr in (childElem.getAttributes() ?? Attributes()).asList() {
                        try wrapper.attr(attr.getKey(), attr.getValue())
                    }

                    // apply any accumulated inline marks to the wrapper
                    var nodeToInsert: Node = wrapper
                    for mark in marks.reversed() {
                        let markEl = Element(Tag(mark.elementName), "")
                        for attr in mark.attributes.asList() {
                            try markEl.attr(attr.getKey(), attr.getValue())
                        }
                        try markEl.appendChild(nodeToInsert)
                        nodeToInsert = markEl
                    }

                    try taggedXml.appendChild(nodeToInsert)

                    // marks are “consumed” now that we’ve wrapped them
                    state = try tagSentencesInXml(
                        chapterId: chapterId,
                        state: state,
                        sentences: sentences,
                        currentNode: childElem,
                        taggedSentences: &taggedSentences,
                        marks: [],              // safe to drop—already applied
                        taggedXml: wrapper
                    )
                    
                    if childElem.hasAttr(Self.dataSpaceAfterAttrName) {
                        consumeOneExpectedWhitespaceIfPresent(sentences: sentences, state: &state)
                    }
                }
                else {
                    // INLINE: accumulate as marks, keep same parent
                    let attrs = childElem.getAttributes() ?? Attributes()
                    let inlineMark = Mark(elementName: name, attributes: attrs)
                    state = try tagSentencesInXml(
                        chapterId: chapterId,
                        state: state,
                        sentences: sentences,
                        currentNode: childElem,
                        taggedSentences: &taggedSentences,
                        marks: marks + [inlineMark],
                        taggedXml: taggedXml
                    )

                    if childElem.hasAttr(Self.dataSpaceAfterAttrName) {
                        consumeOneExpectedWhitespaceIfPresent(sentences: sentences, state: &state)
                    }
                }
                continue
            }

            while state.currentSentenceIndex < sentences.count && state.currentNodeProgress != -1 {
                state = try tagSentencesInXml(
                    chapterId: chapterId,
                    state: state,
                    sentences: sentences,
                    currentNode: child,
                    taggedSentences: &taggedSentences,
                    marks: nextMarks,
                    taggedXml: nextTaggedXml
                )
            }
        }

        state.currentNodeProgress = -1
        return state
    }
}

extension XHTMLTagger {
    
    func tag( sentences:[String], in doc:Document, chapterId: String ) throws  {
        guard let body = try doc.select("body").first() else {
            throw StoryAlignError("no <body> found")
        }

        //  make a deep-clone of <body> (with all its children)
        //  by passing in an empty <body> orphan as the “clone” target
        //
        guard let bodyClone = body.copy(clone: Element(Tag("body"), "")) as? Element else {
          throw StoryAlignError("couldn't clone <body>")
        }

        // clear out the real body so it can be repopulated
        body.empty()
        
        
        var taggedSentences = Set<Int>()
        try tagSentencesInXml(
            chapterId: chapterId,
            state: TagState(currentSentenceIndex: 0, currentSentenceProgress: 0, currentNodeProgress: 0),
            sentences: sentences,
            currentNode: bodyClone,
            taggedSentences: &taggedSentences,
            marks: [],
            taggedXml: body
        )

        try  DupSpanMerger().mergeDupSpans(in: doc, anchorSpanPfx: chapterId, logger: logger)
        //try  mergeDupSpans(in: doc, chapterId: chapterId)

        /*
         * findEmptySpans is (relatively) expensive do don't do this if not testing
        if let emptySpans = try? findEmptySentenceSpans(in: doc) {
            if !emptySpans.isEmpty {
                logger.log( .info, "Found \(emptySpans.count) empty sentence spans after tagging")
            }
        }*/
    }
    
    func tagAndFormat( sentences:[String], in doc:Document, chapterId: String ) throws -> String {
        try tag(sentences: sentences, in: doc, chapterId: chapterId+"-sentence")
        return try prepareXhtmlOutput(from: doc)
    }

    
    //func tag( epub:EpubDocument, manifestItem:EpubManifestItem, chapterId: String) async throws -> String {
    func tag( epub:EpubDocument, alignedChapter:AlignedChapter) async throws -> String {
        let manifestItem = alignedChapter.manifestItem
        let chapterId = alignedChapter.manifestItem.id
        let xhtml = manifestItem.xmlText
        let doc = try SwiftSoup.parse(xhtml)
     
        guard let head = doc.head() else {
            throw StoryAlignError("no <head> found")
        }
        
        let rootUrl = epub.opfURL.deletingLastPathComponent()
        let manifestUrl = manifestItem.filePath?.deletingLastPathComponent() ?? rootUrl
        let relUrlStr = rootUrl.relative(to: manifestUrl )
        let styleCss = "\(AssetPaths.styles)/storyalign.css"
        let stylePath = relUrlStr.isEmpty ? styleCss : "\(relUrlStr)/\(styleCss)"
        
        try head.appendElement("link")
            .attr("rel", "stylesheet")
            .attr("href", stylePath)
            .attr("type", "text/css")
        
        let chapterSentencePfx = chapterId + "-" + Self.sentenceTagPfx
        
        if sessionConfig.granularityExpansion != nil {
            let words = alignedChapter.alignedWords.map { $0.xhtmlSentence }
            let sentences = alignedChapter.alignedSentences.map { $0.xhtmlSentence }
            return try tagAndNest(words: words, sentences: sentences, chapterId: chapterId, doc: doc)
        }
        
        let units = (sessionConfig.granularity.useWordTokenizer) ? alignedChapter.alignedWords : alignedChapter.alignedSentences
        let sentences = units.map { $0.xhtmlSentence }
        try tag(sentences:sentences,  in: doc, chapterId:chapterSentencePfx)

        //return try doc.outerHtml()
        let retStr = try prepareXhtmlOutput(from: doc)
        return retStr
    }
    
    func tagAndNest( words:[String], sentences:[String], chapterId:String , doc:Document) throws -> String {
        let chapterWordPfx = chapterId + "-" + Self.wordTagPfx
        try tag(sentences:words,  in: doc, chapterId:chapterWordPfx)
        
        let chapterSentencePfx = chapterId + "-" + Self.sentenceTagPfx
        try tag(sentences:sentences,  in: doc, chapterId:chapterSentencePfx)

        let maxDepth = sessionConfig.granularityExpansion?.units
        try WordSpanNester().nestWordSpans(in: doc, sentencePfx: chapterSentencePfx, wordPfx: chapterWordPfx, maxDepth:maxDepth)
        
        /*
        if let deepestNesting = try WordSpanNester().deepestNestedSentence(in: doc, sentencePfx: chapterSentencePfx, wordPfx: chapterWordPfx) {
            if deepestNesting.depth > 256 {
                let sentenceSpanId = deepestNesting.sentence.id()
                let sentenceId = Int(sentenceSpanId.replacing( chapterSentencePfx, with:"" ))
                let sentenceText = sentenceId == nil ? sentenceSpanId :  sentences[sentenceId!]
                logger.log( .warn,  "Very deep nesting: \(deepestNesting.depth) for sentence: \(sentenceText) " )
            }
        }*/
        
        let retStr = try prepareXhtmlOutput(from: doc)
        return retStr
        
        /*
        let taggedWordXml = try prepareXhtmlOutput(from: doc)
        let taggedWordDoc = try SwiftSoup.parse( taggedWordXml )
        let chapterSentencePfx = chapterId + "-" + Self.sentenceTagPfx
        try tag(sentences:sentences,  in: taggedWordDoc, chapterId:chapterSentencePfx)

        let taggedSentencesXml = try prepareXhtmlOutput(from: taggedWordDoc)
            .replacing( /\ <\/span> <span/, with: " </span><span" )
        let taggedSentencesDoc = try SwiftSoup.parse( taggedSentencesXml )
        try nestWordSpans(in: taggedSentencesDoc)
        let retStr = try prepareXhtmlOutput(from: taggedSentencesDoc)
        return retStr
         */
    }

}

struct TagState {
    var currentSentenceIndex: Int
    var currentSentenceProgress: Int
    var currentNodeProgress: Int

    // streaming emission state (Option B)
    var openSentenceOwner: ObjectIdentifier? = nil
    var openSentenceId: Int? = nil
    var openSentenceSpan: Element? = nil
    var openMarkSigs: [String] = []
    var openMarkElems: [Element] = []
}

struct Mark {
    let elementName: String
    let attributes: Attributes
}




extension XHTMLTagger {
    func prepareXhtmlOutput( from doc:Document ) throws -> String {
        doc.outputSettings()
            .syntax(syntax:.xml)

        let html = try doc.xmlFormatted()
        return html
    }
}


extension XHTMLTagger {
    static func isSentenceId(_ id: String) -> Bool {
        guard let r = id.range(of: "-\(Self.sentenceTagPfx)", options: .backwards) else { return false }
        let suffix = id[r.upperBound...]
        if suffix.isEmpty { return false }
        return suffix.allSatisfy { $0.isNumber }
    }
    static func isWordId(_ id: String) -> Bool {
        guard let r = id.range(of: "-\(Self.wordTagPfx)", options: .backwards) else { return false }
        let suffix = id[r.upperBound...]
        if suffix.isEmpty { return false }
        return suffix.allSatisfy { $0.isNumber }
    }

    private func isEmptyText(_ e: Element) throws -> Bool {
        try e.text().trimmed().isEmpty
    }


    func findEmptySentenceSpans(in doc: Document) throws -> [Element] {
        try doc.select("span[id]").array().filter {
            if $0.tagName() != "span" {
                return false
            }
            let attrId = try $0.attr("id")
            if !Self.isSentenceId(attrId) && !Self.isWordId(attrId) {
                return false
            }
            return try isEmptyText($0)
        }
    }
}
