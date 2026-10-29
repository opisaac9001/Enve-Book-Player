import Foundation

private struct CTCTimingCoordinate: Hashable, Comparable {
    let file: Int
    let time: Double

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.file == rhs.file ? lhs.time < rhs.time : lhs.file < rhs.file
    }
}

enum CTCSentenceChain {
    static func ordered(_ candidates: [Int: CTCSentenceCandidate]) throws -> [(index: Int, candidate: CTCSentenceCandidate)] {
        let items = candidates.sorted { $0.key < $1.key }.filter {
            let range = $0.value.sentence.sentenceRange
            return range.start.isFinite && range.end.isFinite && range.end - range.start >= 0.04
        }
        guard !items.isEmpty else { return [] }
        let ends = Array(Set(items.map { CTCTimingCoordinate(file: $0.value.sentence.sentenceRange.audioFile.index, time: $0.value.sentence.sentenceRange.end) })).sorted()
        let starts = Array(Set(items.map { CTCTimingCoordinate(file: $0.value.sentence.sentenceRange.audioFile.index, time: $0.value.sentence.sentenceRange.start) })).sorted()
        let endRanks = Dictionary(uniqueKeysWithValues: ends.enumerated().map { ($0.element, $0.offset + 1) })
        let startRanks = Dictionary(uniqueKeysWithValues: starts.enumerated().map { ($0.element, $0.offset + 1) })
        let points = items.map { item in
            let range = item.value.sentence.sentenceRange
            return (x: endRanks[CTCTimingCoordinate(file: range.audioFile.index, time: range.end)]!, y: startRanks[CTCTimingCoordinate(file: range.audioFile.index, time: range.start)]!)
        }
        var rows = [[Int]](repeating: [], count: ends.count + 1)
        for point in points {
            var x = point.x
            while x < rows.count {
                rows[x].append(point.y)
                x += x & -x
            }
        }
        for row in rows.indices { rows[row] = Array(Set(rows[row])).sorted() }
        var tree = rows.map { [Int](repeating: -1, count: $0.count + 1) }
        var lengths = [Int](repeating: 1, count: items.count)
        var scores = items.map { Double($0.value.score) }
        var predecessors = [Int](repeating: -1, count: items.count)

        func preferred(_ lhs: Int, _ rhs: Int) -> Int {
            if lhs < 0 { return rhs }
            if rhs < 0 { return lhs }
            if lengths[lhs] != lengths[rhs] { return lengths[lhs] > lengths[rhs] ? lhs : rhs }
            if scores[lhs] != scores[rhs] { return scores[lhs] > scores[rhs] ? lhs : rhs }
            return min(lhs, rhs)
        }

        func upperBound<T: Comparable>(_ values: [T], _ value: T) -> Int {
            var low = 0
            var high = values.count
            while low < high {
                let middle = (low + high) / 2
                if values[middle] <= value { low = middle + 1 } else { high = middle }
            }
            return low
        }

        var best = -1
        for index in items.indices {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            let range = items[index].value.sentence.sentenceRange
            let maximumEnd = CTCTimingCoordinate(file: range.audioFile.index, time: min(range.start + 0.499, range.end - 0.04))
            let maximumStart = CTCTimingCoordinate(file: range.audioFile.index, time: range.start - 0.04)
            var x = upperBound(ends, maximumEnd)
            let y = upperBound(starts, maximumStart)
            var predecessor = -1
            while x > 0 {
                var column = upperBound(rows[x], y)
                while column > 0 {
                    predecessor = preferred(predecessor, tree[x][column])
                    column -= column & -column
                }
                x -= x & -x
            }
            if predecessor >= 0 {
                lengths[index] = lengths[predecessor] + 1
                scores[index] += scores[predecessor]
                predecessors[index] = predecessor
            }
            x = points[index].x
            while x < rows.count {
                var column = upperBound(rows[x], points[index].y)
                while column < tree[x].count {
                    tree[x][column] = preferred(tree[x][column], index)
                    column += column & -column
                }
                x += x & -x
            }
            best = preferred(best, index)
        }
        var chain: [Int] = []
        while best >= 0 {
            chain.append(best)
            best = predecessors[best]
        }
        let result = chain.reversed().map { (index: items[$0].key, candidate: items[$0].value) }
        for pair in zip(result, result.dropFirst()) {
            let lhs = pair.0.candidate.sentence.sentenceRange
            let rhs = pair.1.candidate.sentence.sentenceRange
            if lhs.audioFile.index == rhs.audioFile.index, lhs.end > rhs.start { lhs.end = rhs.start }
        }
        return result
    }
}
