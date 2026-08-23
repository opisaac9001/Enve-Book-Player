//
// MediaOverlay.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//

import Foundation

struct MediaOverlay {
    let baseURL: URL
    let manifestItem: EpubManifestItem
    let sentenceRanges: [SentenceRange]
    let sentenceTagPfx: String 

    var itemId: String {
        manifestItem.id + "_overlay"
    }

    var href: String {
        let basename = manifestItem.filePath!.deletingPathExtension().lastPathComponent
        return "\(AssetPaths.mediaOverlays)/\(basename).smil"
    }

    var filePath: URL {
        baseURL.appendingPathComponent(href)
    }

    var audioFiles: [AudioFile] {
        Array(Set(sentenceRanges.map(\.audioFile))).sorted { $0.filePath.path() < $1.filePath.path() }
    }

    var overlayXml: String {
        let dots = {
            let depth = AssetPaths.mediaOverlays.split(separator: "/").count
            guard depth > 0 else { return "." }
            return Array(repeating: "..", count: depth).joined(separator: "/")
        }()

        var xml = """
        <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
          <body>
            <seq id="\(itemId)" epub:textref="\(dots)/\(manifestItem.href)" epub:type="chapter">

        """

        for sr in sentenceRanges {
            let sid = "\(manifestItem.id)-\(sentenceTagPfx)\(sr.id)"
            let clipBegin = String(format: "%.3fs", sr.start.roundToMs())
            let clipEnd = String(format: "%.3fs", sr.end.roundToMs())

            xml += """
                  <par id="\(sid)">
                    <text src="\(dots)/\(manifestItem.href)#\(sid)"/>
                    <audio src="\(dots)/\(AssetPaths.audio)/\(sr.audioFile.filePath.lastPathComponent)" clipBegin="\(clipBegin)" clipEnd="\(clipEnd)"/>
                  </par>

            """
        }

        xml += """
            </seq>
          </body>
        </smil>

        """
        return xml
    }
}
