//
// Sequence+Extensions.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//

import Foundation

public extension Sequence where Element: Sendable {
    func asyncCompactMap<T: Sendable>(
        concurrency: Int = 1,
        _ transform: @escaping @Sendable (Element) async throws -> T?
    ) async throws -> [T] {
        if concurrency == 1 {
            var out: [T] = []
            for el in self {
                try Task.checkCancellation()
                if let v = try await transform(el) {
                    out.append(v)
                }
            }
            return out
        }

        let elems = Array(self.enumerated())
        var buffer: [(Int, T)] = []
        var iter = elems.makeIterator()

        return try await withThrowingTaskGroup(of: (Int, T?).self) { group in
            let maxC = concurrency > 0 ? concurrency : ProcessInfo.processInfo.processorCount
            let batch = Swift.min(maxC, elems.count)
            
            for _ in 0..<batch {
                try Task.checkCancellation()

                guard let (i, el) = iter.next() else { break }
                group.addTask {
                    try Task.checkCancellation()
                    return (i, try await transform(el))
                }
            }

            do {
                while let (i, maybeV) = try await group.next() {
                    if let v = maybeV { buffer.append((i, v)) }
                    
                    try Task.checkCancellation()
                    if let (j, el) = iter.next() {
                        group.addTask {
                            try Task.checkCancellation()
                            return (j, try await transform(el))
                        }
                    }
                }
            } catch {
                group.cancelAll()
                throw error
            }

            return buffer
                .sorted { $0.0 < $1.0 }
                .map { $0.1 }
        }
    }

    func asyncMap<T: Sendable>(
        concurrency: Int = 1,
        _ transform: @escaping @Sendable (Element) async throws -> T
    ) async throws -> [T] {
        try await asyncCompactMap(concurrency: concurrency) { el in
            try await transform(el)
        }
    }
}

/*
 * needs work
public extension Sequence {
    func tripletsMap(
        _ transform: (_ prev: Element?, _ current: Element?, _ next: Element?) -> (newPrev: Element?, newCurrent: Element?, newNext: Element?)
    ) -> [Element] {
        let arr = Array(self)
        
        if arr.isEmpty {
            return []
        }
        let count = arr.count
        var prev: Element? = nil
        var next: Element? = (count > 1 ? arr[1] : nil)
        var current:Element? = arr[0]
        
        var results: [Element?] = []
        var lastNewCurrent: Element? = nil
        var lastNewNext: Element? = nil

        
        var i = 0
        while i < count {
            let (newPrev, newCurrent, newNext) = transform(prev, current, next)

            results.removeLast(Swift.min(3, results.count) )
            //results.dropLast(2)
            results.append(newPrev)
            results.append(newCurrent)
            results.append(newNext)
            
            lastNewCurrent = newCurrent
            lastNewNext = newNext

            prev = newCurrent
            current = newNext
            next = (i < count - 1 ? arr[i + 1] : nil)
            i += 1
        }
        
        results.append(lastNewCurrent)
        results.append(lastNewNext)
        
        let nonNilResults = results.compactMap { $0 }
        return nonNilResults
    }
}
*/

public extension Sequence where Element: Hashable {
    func unique() -> [Element] {
        var seen = Set<Element>()
        return self.filter { seen.insert($0).inserted }
    }
}


extension Sequence {
    func pairs() -> [(prev: Element?, current: Element)] {
        let arr = Array(self)
        var result = [(Element?, Element)]()
        if arr.isEmpty {
            return []
        }
        result.append( (nil, arr[0]) )
        for i in 1..<arr.count {
            result.append((arr[i - 1], arr[i]))
        }
        return result
    }
}
