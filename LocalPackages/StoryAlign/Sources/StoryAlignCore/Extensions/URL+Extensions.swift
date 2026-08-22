//
// URL+Extensions.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//


import Foundation

extension URL {
    func relative(to base: URL) -> String {
        let baseDir: URL = {
            if base.hasDirectoryPath { return base }
            if !base.pathExtension.isEmpty { return base.deletingLastPathComponent() }
            return base
        }()
        let a = standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let b = baseDir.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        
        var i = 0
        while i < a.count && i < b.count {
            if a[i] != b[i] {
                break
            }
            i += 1
        }

        var comps = [String]()
        for _ in i..<b.count {
            comps.append("..")
        }
        comps.append(contentsOf: a[i...])
        return comps.joined(separator: "/")
    }
}
