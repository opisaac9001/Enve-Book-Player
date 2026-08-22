//
//  DupSpanMerger.swift
//  StoryAlign
//
//  Created by Rich Waters on 2/11/26.
//

import Foundation
import SwiftSoup


struct DupSpanMerger {
    /*
     * Fixes duplicate span ids by collapsing repeated <span id="..."> wrappers into a single canonical wrapper per id. These dups can be created by the tagging when wrapping sentences containing or within othe spans. For each duplicated id, it unwraps all inner occurrences inside sentence spans, then moves the affected sentence spans (plus any immediate same-id sibling spans like <span id="..."><br/></span>) under the canonical wrapper to preserve reading order while eliminating duplicate ids.
     */
    func mergeDupSpans(in doc: Document, anchorSpanPfx:String, logger:Logger) throws {
        
        // Collect all spans-with-id once, grouped by id, and keep ids in first-seen document order.
        let allWithId = try doc.select("*[id]").array()
        //let allWithId = try doc.select("span[id]").array()
        var idCache: [ObjectIdentifier: String] = [:]
        
        func cachedId(_ e: Element ) throws -> String {
            let oid = ObjectIdentifier(e)
            if let v = idCache[oid] { return v }
            let v = try e.attr("id")
            idCache[oid] = v
            return v
        }
        func hasAttrId(_ e:Element ) -> Bool {
            let oid = ObjectIdentifier(e)
            if idCache[oid] != nil {
                return true
            }
            return e.hasAttr("id")
        }
        func removeCachedId(_ e:Element ) {
            let oid = ObjectIdentifier(e)
            idCache.removeValue(forKey: oid)
        }
        
        
        var anchorSpansInDocOrder: [Element] = []
        var byId = [String: [Element]]()
        for s in allWithId {
            let sid = try cachedId(s)
            byId[sid, default: []].append(s)
            if byId[sid]!.count > 1 && s.tagName().lowercased() != byId[sid]!.first!.tagName() {
                logger.log(.warn, "Mixed tag duplicate IDs found. Book probably won't be compliant: \(byId[sid]!.map {  ($0.tagName()) }.joined(separator: ", "))")
            }
            if sid.hasPrefix(anchorSpanPfx) {
                anchorSpansInDocOrder.append(s)
            }
        }
        
        var orderedIds: [String] = []
        var seen = Set<String>()
        for s in allWithId {
            let id = try cachedId(s)
            if (byId[id]?.count ?? 0) > 1 && !seen.contains(id) {
                orderedIds.append(id)
                seen.insert(id)
            }
        }
                
        let dupIdSet = Set(orderedIds)
        var byIdByAnchorSpan: [String: [String: [Element]]] = [:]
        var anchorSpansByInnerId: [String: [Element]] = [:]
        
        for inner in allWithId {
            let innerId = try cachedId(inner)
            if !dupIdSet.contains(innerId) { continue }
            if XHTMLTagger.isWordId(innerId) { continue }
            
            var p = inner.parent()
            while let pe = p {
                if pe.tagName() == "span", hasAttrId(pe) {
                    let pid = try cachedId(pe)
                    if pid.hasPrefix(anchorSpanPfx) {
                        if byIdByAnchorSpan[innerId]?[pid] == nil {
                            anchorSpansByInnerId[innerId, default: []].append(pe)
                        }
                        byIdByAnchorSpan[innerId, default: [:]][pid, default: []].append(inner)
                        break
                    }
                }
                p = pe.parent()
            }
        }
        
        // Track which ids we've already merged so nested/overlapping merges place wrappers consistently.
        var processedIds = Set<String>()
        
        for id in orderedIds {
            // For each duplicated id: gather the sentence spans that contain it (in order) and create the merged wrapper.
            
            guard let group = byId[id], !group.isEmpty else { continue }
            guard group.count > 1 else { continue }
            let isAnchorId = id.hasPrefix(anchorSpanPfx)
            let bySentence = byIdByAnchorSpan[id] ?? [:]
            if !isAnchorId && bySentence.isEmpty { continue }
            
            // Duplicate word ids must be merged in-place (never hoist out of the sentence).
            if XHTMLTagger.isWordId(id) {
                let elems = group.filter { $0.parent() != nil }
                if elems.count > 1 {
                    let first = elems[0]
                    for e in elems.dropFirst() {
                        let eHadSpaceAfter = e.hasAttr(XHTMLTagger.dataSpaceAfterAttrName)
                        
                        while e.childNodeSize() > 0 {
                            let n = e.childNode(0)
                            try first.appendChild(n)
                        }
                        if eHadSpaceAfter && !first.hasAttr(XHTMLTagger.dataSpaceAfterAttrName) {
                            try first.attr(XHTMLTagger.dataSpaceAfterAttrName, "1")
                        }
                        
                        let parent = e.parent()
                        try e.remove()
                        if let p = parent, p.tagName() == "span", p.childNodeSize() == 0 {
                            try p.remove()
                        }
                        //try clearupDupAttrs(e)
                    }
                }
                continue
            }
            
            if isAnchorId {
                let owners = group.compactMap { e -> String? in
                    if e.parent() == nil { return nil }
                    return blockOwnerTag(e)
                }
                if Set(owners).count > 1 {
                    var keep: Element? = nil
                    var keepIdx = Int.max
                    var keepRank = Int.max
                    
                    for (idx, e) in group.enumerated() {
                        if e.parent() == nil { continue }
                        let r = keeperRank(e)
                        if r < keepRank || (r == keepRank && idx < keepIdx) {
                            keep = e
                            keepIdx = idx
                            keepRank = r
                        }
                    }
                    
                    if let keep {
                        for e in group {
                            if e.parent() == nil { continue }
                            if e === keep { continue }
                            try clearupDupAttrs(e)
                        }
                        processedIds.insert(id)
                    }
                    continue
                }
            }
            
            
            var anchorSpans:[Element] = []
            if isAnchorId {
                // When the duplicate id is itself an anchor span id, merge the duplicate anchor spans.
                // If any are nested inside another same-id span, strip their attrs and don't treat them as movers.
                for e in group {
                    if e.parent() == nil { continue }
                    if let pe = e.parent() , pe.tagName() == "span", hasAttrId(pe) {
                        let pid = try cachedId(pe)
                        if pid == id {
                            try clearupDupAttrs(e)
                            continue
                        }
                    }
                    anchorSpans.append(e)
                }
            } else {
                anchorSpans = anchorSpansByInnerId[id] ?? []
            }
            if anchorSpans.isEmpty { continue }

            let tagName = byId[id]?.first?.tagName() ?? "span"
            let merged = Element(Tag(tagName), "")
            for a in (group[0].getAttributes() ?? Attributes()).asList() {
                try merged.attr(a.getKey(), a.getValue())
            }
            
            // Insert the merged wrapper before/after the first relevant anchor span, respecting earlier processed wrappers.
            let firstAnchorSpan = anchorSpans[0]
            var anchor: Element = firstAnchorSpan
            
            var placeAfter = false
            var p = firstAnchorSpan.parent()
            while let parent = p {
                if parent.tagName() == "span", hasAttrId(parent) {
                    let pid = try cachedId(parent)
                    if processedIds.contains(pid), pid != id {
                        anchor = parent
                        placeAfter = true
                        break
                    }
                }
                p = parent.parent()
            }
            if placeAfter {
                try _ = anchor.after(merged)
            } else {
                try anchor.before(merged)
            }
            
            for anchorSpan in anchorSpans {
                // Within each anchor span: unwrap all inner spans with this id, then (if not nested) move the anchor span into merged and absorb trailing same-id siblings.
                if anchorSpan.parent() == nil { continue }
                
                if !isAnchorId {
                    let sid = try cachedId(anchorSpan)
                    let inners = bySentence[sid] ?? []
                    for inner in inners {
                        if inner.parent() == nil { continue }
                        try clearupDupAttrs(inner)
                    }
                } else {
                    // The moved anchor spans must lose the duplicate id; merged keeps it.
                    try clearupDupAttrs(anchorSpan)
                }
                
                var trailingNodes: [Node] = []
                var sib = anchorSpan.nextSibling()
                while let n = sib {
                    if let e = n as? Element {
                        if e.tagName() == "span", hasAttrId(e) {
                            if (try cachedId(e)) == id {
                                trailingNodes.append(e)
                                sib = e.nextSibling()
                                continue
                            }
                        }
                        if e.tagName() == "br" {
                            trailingNodes.append(e)
                            sib = e.nextSibling()
                            continue
                        }
                    }
                    if isWhitespaceTextNode(n) {
                        trailingNodes.append(n)
                        sib = n.nextSibling()
                        continue
                    }
                    break
                }
                
                try merged.appendChild(anchorSpan)
                for n in trailingNodes {
                    if let e = n as? Element, e.tagName() == "span", hasAttrId(e) {
                        if (try cachedId(e)) == id {
                            try clearupDupAttrs(e)
                        }
                    }
                    try merged.appendChild(n)
                }
            }
            
            processedIds.insert(id)
        }
        
        func clearupDupAttrs(_ e:Element ) throws {
            let keepKey = XHTMLTagger.dataSpaceAfterAttrName

            let keys = (e.getAttributes() ?? Attributes()).asList().map { $0.getKey() }
            for k in keys where k != keepKey {
                if k == "id" {
                    removeCachedId( e )
                }
                try e.removeAttr(k)
            }
            try e.attr( XHTMLTagger.dataDicardableWrapper, "1" )
        }
        
        func isWhitespaceTextNode(_ n: Node) -> Bool {
            guard let t = n as? TextNode else { return false }
            return t.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        
        func blockOwnerTag(_ e: Element) -> String? {
            var p = e.parent()
            while let pe = p {
                let t = pe.tagName()
                if t == "p" || t == "figure" {
                    return t
                }
                p = pe.parent()
            }
            return nil
        }
        
        func keeperRank(_ e: Element) -> Int {
            switch blockOwnerTag(e) {
                case "p": return 0
                case "figure": return 1
                default: return 2
            }
        }

    }
}
 

