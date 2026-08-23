//
// DomHelpers.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//

import Foundation
import SwiftSoup

struct DomHelpers {
    static func addItem(to manifest: Element, id: String, href: String, mediaType: String, properties:String = "") throws {
        let newItem = Element(Tag("item"), "")
        try newItem.attr("id", id)
        try newItem.attr("href", href)
        try newItem.attr("media-type", mediaType)
        if !properties.isEmpty {
            try newItem.attr( "properties", properties)
        }
        try manifest.appendChild(newItem)
    }
    
    
    static func buildElement(withName name:String, attributes: [(String, String)], text: String? = nil) throws -> Element {
        let meta = Element(Tag(name), "")
        for (key, value) in attributes {
            try meta.attr(key, value)
        }
        if let text = text {
            try meta.appendChild(TextNode(text, ""))
        }
        return meta
    }

    
    static func buildMeta(attributes: [(String, String)], text: String?) throws -> Element {
        return try buildElement(withName: "meta", attributes: attributes, text: text)
    }
    
    static func buildMeta(refines:String, property: String, scheme:String? = nil, text:String? = nil) throws -> Element {
        let attributes=[
            ("property",property),
            ("refines", "#\(refines)") ,
            scheme.map { ( "scheme", $0 ) }
        ].compactMap { $0 }

        return try buildMeta( attributes:attributes, text: text )
    }
    
}
