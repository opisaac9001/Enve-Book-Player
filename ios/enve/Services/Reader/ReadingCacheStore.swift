import Foundation
import Observation
import os

nonisolated struct ReadingCacheClearResult: Equatable, Sendable {
    let removedBytes: Int64
    let remainingBytes: Int64
    let activeBytes: Int64

    var retainsActiveAssets: Bool { activeBytes > 0 }
}

nonisolated enum ReadingCacheError: Error, Equatable {
    case outsideManagedRoots
}

nonisolated enum ReadingCacheAdmission: Sendable {
    case required
    case ifRoom(sparing: URL)
}

nonisolated final class ReadingCacheWriteLease: Sendable {
    private let valid = OSAllocatedUnfairLock(initialState: true)

    var isValid: Bool { valid.withLock { $0 } }

    func revoke() {
        valid.withLock { $0 = false }
    }
}

@MainActor
@Observable
final class ReadingCacheStore {
    static let limitOptionsMegabytes = [64, 128, 256, 512, 1024]
    static let defaultLimitMegabytes = 256
    static let managedDirectoryNames: Set<String> = Set(ReadingCacheDisk.roots.map { $0.name })
    private static let limitKey = "readingCacheLimitMegabytes"

    private(set) var limitMegabytes: Int
    private(set) var limitBytes: Int64
    @ObservationIgnored private(set) var clearGeneration = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let disk: ReadingCacheDisk
    @ObservationIgnored private var maintenance: Task<Void, Never>?
    @ObservationIgnored private var preparations: [String: String] = [:]

    init(cachesDirectory: URL, defaults: UserDefaults = .standard, byteLimit: Int64? = nil) {
        self.defaults = defaults
        disk = ReadingCacheDisk(cachesDirectory: cachesDirectory)
        let stored = defaults.integer(forKey: Self.limitKey)
        let megabytes = Self.limitOptionsMegabytes.contains(stored) ? stored : Self.defaultLimitMegabytes
        limitMegabytes = megabytes
        limitBytes = byteLimit ?? Self.bytes(megabytes: megabytes)
    }

    func setLimit(megabytes: Int) async {
        guard Self.limitOptionsMegabytes.contains(megabytes) else { return }
        defaults.set(megabytes, forKey: Self.limitKey)
        limitMegabytes = megabytes
        limitBytes = Self.bytes(megabytes: megabytes)
        await trim()
    }

    func sizeBytes() async -> Int64 {
        await disk.measure()
    }

    func retainPreparation(owner: String, for bookID: String) {
        preparations[bookID] = owner
    }

    func claimPreparation(for bookID: String) -> String? {
        preparations.removeValue(forKey: bookID)
    }

    func discardPreparation(owner: String, for bookID: String) {
        if preparations[bookID] == owner { preparations[bookID] = nil }
    }

    func trim() async {
        await disk.trim(limit: limitBytes, rescan: true)
    }

    func clear() async -> ReadingCacheClearResult {
        clearGeneration += 1
        return await disk.clear(generation: clearGeneration)
    }

    func protect(_ urls: [URL], owner: String) async {
        await disk.protect(urls, owner: owner)
    }

    func release(owner: String) async {
        await disk.release(owner: owner)
        scheduleMaintenance()
    }

    func touch(_ url: URL) async {
        await disk.touch(url)
    }

    func hasFile(at url: URL) async -> Bool {
        await disk.hasFile(at: url)
    }

    func data(at url: URL) async -> Data? {
        await disk.read(url)
    }

    @discardableResult
    func write(
        _ data: Data,
        to url: URL,
        lease: ReadingCacheWriteLease,
        generation: Int,
        admission: ReadingCacheAdmission = .required
    ) async throws -> Bool {
        let outcome = try await disk.write(
            data, to: url, lease: lease, generation: generation, limit: limitBytes, admission: admission)
        if outcome.isOverBudget {
            scheduleMaintenance()
        }
        return outcome.isWritten
    }

    private func scheduleMaintenance() {
        guard maintenance == nil else { return }
        maintenance = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.disk.trim(limit: self.limitBytes, rescan: false)
            self.maintenance = nil
        }
    }

    private static func bytes(megabytes: Int) -> Int64 {
        Int64(megabytes) * 1_048_576
    }
}

private actor ReadingCacheDisk {
    nonisolated static let roots: [(name: String, unitDepth: Int)] = [
        ("ReaderEbooks", 1),
        ("ConvertedEbooks", 1),
        ("ComicPages", 1),
        ("StreamedEpubs", 2),
        ("StreamedPages", 2),
    ]

    nonisolated struct WriteOutcome: Sendable {
        let isWritten: Bool
        let isOverBudget: Bool
    }

    nonisolated private struct Unit {
        var bytes: Int64
        var lastUsed: Date
    }

    private let fileManager = FileManager()
    private let basePath: String
    private let rawBasePath: String
    private var index: [String: Unit]?
    private var protectedPaths: [String: Set<String>] = [:]
    private var generation = 0

    init(cachesDirectory: URL) {
        rawBasePath = cachesDirectory.standardizedFileURL.path
        basePath = cachesDirectory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func measure() -> Int64 {
        scan().values.reduce(0) { $0 + $1.bytes }
    }

    func trim(limit: Int64, rescan: Bool) {
        if rescan || index == nil {
            _ = scan()
        }
        _ = evict(toFit: limit, sparing: nil)
    }

    func clear(generation: Int) -> ReadingCacheClearResult {
        self.generation = generation
        var units = scan()
        var removed: Int64 = 0
        for (path, unit) in units where !isProtected(path) {
            guard remove(path) else { continue }
            removed += unit.bytes
            units[path] = nil
        }
        index = units
        let remaining = units.values.reduce(0) { $0 + $1.bytes }
        let active = units.filter { isProtected($0.key) }.values.reduce(0) { $0 + $1.bytes }
        return ReadingCacheClearResult(removedBytes: removed, remainingBytes: remaining, activeBytes: active)
    }

    func protect(_ urls: [URL], owner: String) {
        protectedPaths[owner] = urls.isEmpty ? nil : Set(urls.map(canonicalPath))
    }

    func release(owner: String) {
        protectedPaths[owner] = nil
    }

    func touch(_ url: URL) {
        guard let unit = unitPath(containing: canonicalPath(url)) else { return }
        let now = Date()
        try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: unit)
        index?[unit]?.lastUsed = now
    }

    func hasFile(at url: URL) -> Bool {
        let path = canonicalPath(url)
        return unitPath(containing: path) != nil && fileManager.fileExists(atPath: path)
    }

    func read(_ url: URL) -> Data? {
        let path = canonicalPath(url)
        guard unitPath(containing: path) != nil, let data = fileManager.contents(atPath: path) else { return nil }
        touch(url)
        return data
    }

    func write(
        _ data: Data,
        to url: URL,
        lease: ReadingCacheWriteLease,
        generation: Int,
        limit: Int64,
        admission: ReadingCacheAdmission
    ) throws -> WriteOutcome {
        let path = canonicalPath(url)
        guard let unit = unitPath(containing: path) else { throw ReadingCacheError.outsideManagedRoots }
        let dropped = WriteOutcome(isWritten: false, isOverBudget: false)
        guard lease.isValid, generation == self.generation, !Task.isCancelled else { return dropped }

        let bytes = Int64(data.count)
        if case .ifRoom(let sparing) = admission {
            guard bytes <= limit, evict(toFit: limit - bytes, sparing: canonicalPath(sparing)) + bytes <= limit else {
                return dropped
            }
        }

        try fileManager.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        // The lease can be revoked while the write is in progress; never leave the file behind.
        guard lease.isValid else {
            try? fileManager.removeItem(atPath: path)
            return dropped
        }

        guard index != nil else { return WriteOutcome(isWritten: true, isOverBudget: true) }
        let now = Date()
        if unit == path {
            index?[unit] = Unit(bytes: bytes, lastUsed: now)
        } else {
            index?[unit, default: Unit(bytes: 0, lastUsed: now)].bytes += bytes
            index?[unit]?.lastUsed = now
        }
        return WriteOutcome(isWritten: true, isOverBudget: indexedBytes > limit)
    }

    private var indexedBytes: Int64 {
        (index ?? [:]).values.reduce(0) { $0 + $1.bytes }
    }

    private func evict(toFit limit: Int64, sparing: String?) -> Int64 {
        var units = index ?? scan()
        var total = units.values.reduce(0) { $0 + $1.bytes }
        guard total > limit else { return total }
        let candidates = units
            .filter { entry in
                !isProtected(entry.key) && !(sparing.map { Self.path(entry.key, isWithin: $0) } ?? false)
            }
            .sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (path, unit) in candidates {
            guard total > limit else { break }
            if remove(path) {
                total -= unit.bytes
                units[path] = nil
            }
        }
        index = units
        return total
    }

    private func scan() -> [String: Unit] {
        var units: [String: Unit] = [:]
        for root in Self.roots {
            for path in unitPaths(in: basePath + "/" + root.name, depth: root.unitDepth) {
                units[path] = measureUnit(at: path)
            }
        }
        index = units
        return units
    }

    private func unitPaths(in directory: String, depth: Int) -> [String] {
        let children = ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { directory + "/" + $0 }
        guard depth > 1 else { return children }
        return children.flatMap { isDirectory($0) ? unitPaths(in: $0, depth: depth - 1) : [$0] }
    }

    private func measureUnit(at path: String) -> Unit {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .contentAccessDateKey]
        let url = URL(fileURLWithPath: path)
        guard let rootValues = try? url.resourceValues(forKeys: Set(keys)) else { return Unit(bytes: 0, lastUsed: .distantPast) }
        var unit = Unit(bytes: 0, lastUsed: Self.lastUse(rootValues))
        guard rootValues.isRegularFile != true else {
            unit.bytes = Int64(rootValues.fileSize ?? 0)
            return unit
        }
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys)
        while let child = enumerator?.nextObject() as? URL {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isRegularFile == true {
                unit.bytes += Int64(values.fileSize ?? 0)
            }
            unit.lastUsed = max(unit.lastUsed, Self.lastUse(values))
        }
        return unit
    }

    private func remove(_ path: String) -> Bool {
        do {
            try fileManager.removeItem(atPath: path)
        } catch {
            guard !fileManager.fileExists(atPath: path) else { return false }
        }
        let parent = (path as NSString).deletingLastPathComponent
        if unitPath(containing: parent) == nil, !Self.roots.contains(where: { basePath + "/" + $0.name == parent }),
            (try? fileManager.contentsOfDirectory(atPath: parent))?.isEmpty == true
        {
            try? fileManager.removeItem(atPath: parent)
        }
        return true
    }

    private func isProtected(_ unit: String) -> Bool {
        protectedPaths.values.contains { paths in
            paths.contains { Self.path($0, isWithin: unit) || Self.path(unit, isWithin: $0) }
        }
    }

    private func unitPath(containing path: String) -> String? {
        for root in Self.roots {
            let rootPath = basePath + "/" + root.name
            guard path.hasPrefix(rootPath + "/") else { continue }
            let components = path.dropFirst(rootPath.count + 1).split(separator: "/")
            guard components.count >= root.unitDepth else { return nil }
            return rootPath + "/" + components.prefix(root.unitDepth).joined(separator: "/")
        }
        return nil
    }

    private func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        for prefix in [basePath, rawBasePath, "/private" + basePath] where path == prefix || path.hasPrefix(prefix + "/") {
            return basePath + path.dropFirst(prefix.count)
        }
        return path
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    nonisolated private static func path(_ path: String, isWithin ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor + "/")
    }

    nonisolated private static func lastUse(_ values: URLResourceValues) -> Date {
        let modified = values.contentModificationDate ?? .distantPast
        // Scanning lists directories, which can update their access dates; only file reads count.
        guard values.isRegularFile == true else { return modified }
        return max(values.contentAccessDate ?? .distantPast, modified)
    }
}
