//
// StoryAlignVersion.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//
//

import Foundation


/*
 * These lets are auto-filled by scripts/update_version.sh.  The Makefile uses the scripts to invoke changes. It would be nice if SPM prebuild plugins worked correctly, which would address the build issue, at least, but they don't.
 */
fileprivate let storyAlignVersion = "1.2.3"
////////////////////////


fileprivate let storyAlignToolName = "StoryAlignCore"

public struct StoryAlignVersion : Sendable {
    public let versionNum = storyAlignVersion
    public let toolName:String
    
    public init(toolName: String? = nil ) {
        self.toolName = toolName ?? storyAlignToolName
    }
}

extension StoryAlignVersion {
    var components: [String] {
        versionNum.split(separator: ".").map(\.description)
    }
    
    var beta:Int? {
        if components.count < 4 {
            return nil
        }
        return (Int(components[3]) ?? 0)  + 1
    }
    var patch:String? {
        if components.count < 3 {
            return nil
        }
        let patchStr = components[2]
        if patchStr == "0" {
            return nil
        }
        return patchStr
    }
    var major:String {
        return components.first ?? ""
    }
    var minor:String {
        return components.count > 1 ? components[1] : "0"
    }
}

public extension StoryAlignVersion {
    var shortVersionStr : String {
        var devStr = ""
        #if DEBUG
            devStr="-dev"
        #endif
        let majorMinorPatch = [major, minor, patch ].compactMap { $0 }.joined(separator: ".")
        guard let betaN = beta else {
            return "\(majorMinorPatch)\(devStr)"
        }
        return "\(majorMinorPatch)-beta\(betaN)\(devStr)"
    }
    
    func fullVersionStr(buildStr:String) -> String {
        return "\(shortVersionStr), build \(buildStr)"
    }
}
