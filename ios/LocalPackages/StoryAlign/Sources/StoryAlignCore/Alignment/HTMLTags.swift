//
//  HTMLTags.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//

struct HTMLTags {
    static let contentSectioning: Set<String> = [
        "address", "article", "aside", "footer", "header",
        "h1", "h2", "h3", "h4", "h5", "h6", "hgroup", "main", "nav", "section", "search"
    ]
    static let textContent: Set<String> = [
        "blockquote","dd","div","dl","dt","figcaption","figure",
        "hr","li","menu","ol","p","pre","ul"
    ]
    static let tableParts: Set<String> = [
        "table","thead","th","tbody","tr","td","colgroup","caption","tfoot"
    ]
    
    static let inline:Set<String> =  ["span", "strong", "i", "em", "b", "u"]

    //let atomElements: Set<String> = [
    //"img", "br", "hr", "input", "meta", "link"
    //]
    //let inlineContainerElements: Set<String> = [
    //"i","em","b","u", "strong"
    //]
    
    static let blocks: Set<String> = textContent.union(contentSectioning).union(tableParts)
}
