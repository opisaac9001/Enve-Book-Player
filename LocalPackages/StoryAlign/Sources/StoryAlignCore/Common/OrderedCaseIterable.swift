//
//  OrderedCaseIterable.swift
//  StoryAlign
//
//  Created by Rich Waters on 1/25/26.
//


public protocol OrderedCaseIterable: CaseIterable, Comparable, Sendable {
    static var orderedCases: [Self] { get }
    var ordinalValue: Int { get }
}

public extension OrderedCaseIterable {
    var ordinalValue: Int { Self.orderedCases.firstIndex(of: self)! }
    
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.ordinalValue < rhs.ordinalValue
    }
    static func > (lhs: Self, rhs: Self) -> Bool {
        lhs.ordinalValue > rhs.ordinalValue
    }
    static func >= (lhs: Self, rhs: Self) -> Bool {
        lhs.ordinalValue >= rhs.ordinalValue
    }
}
