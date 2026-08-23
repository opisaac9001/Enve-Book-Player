//
//  Granularity.swift
//  StoryAlign
//
//  Created by Rich Waters on 2/11/26.
//

import Foundation

public enum Granularity: String , OrderedCaseIterable, Codable, Sendable {
    case sentence
    case phrase
    case segment
    case group
    case word
    
    public static let orderedCases: [Granularity] =  [.word, .group, .segment, .phrase, .sentence] 

    public var useWordTokenizer:Bool {
        switch self {
            case .segment, .group, .word:
                return true
            default:
                return false
        }
    }
}

public enum GranularityExpansion: Sendable, Equatable, Codable {
    case scope(Granularity)   // keep active until this boundary (>= granularity)
    case units(Int)           // keep at most N granularity units active
    
    var scope: Granularity? {
        guard case .scope(let g) = self else { return nil }
        return g
    }

    var units: Int? {
        guard case .units(let n) = self else { return nil }
        return n
    }
    
    var description: String {
        switch self {
            case .scope(let granularity): return "\(granularity)"
            case .units(let number): return "\(number)"
        }
    }
}

