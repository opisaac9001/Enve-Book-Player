import Foundation
import UIKit

@MainActor
final class WatchCoverStore {
    static let shared = WatchCoverStore()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let root = URL.documentsDirectory.appendingPathComponent("Covers", isDirectory: true)

    private init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    nonisolated static func sanitized(_ id: String) -> String {
        id.map { "/\\:?&=%#".contains($0) ? "-" : $0 }.map(String.init).joined()
    }

    private func fileURL(for stableId: String) -> URL {
        root.appendingPathComponent("\(Self.sanitized(stableId)).jpg")
    }

    func cachedImage(for stableId: String) -> UIImage? {
        if let image = memory.object(forKey: stableId as NSString) {
            return image
        }
        if let data = try? Data(contentsOf: fileURL(for: stableId)), let image = UIImage(data: data) {
            memory.setObject(image, forKey: stableId as NSString)
            return image
        }
        return nil
    }

    func image(for stableId: String) async -> UIImage? {
        if let cached = cachedImage(for: stableId) {
            return cached
        }
        if let existing = inFlight[stableId] {
            return await existing.value
        }
        let fetch = Task { () -> UIImage? in
            guard
                let reply = try? await PhoneLink.shared.request(
                    .requestCover,
                    WatchCoverRequest(stableId: stableId, maxPixels: 240),
                    as: WatchCoverReply.self
                ), let data = reply.jpeg, let image = UIImage(data: data)
            else {
                return nil
            }
            try? data.write(to: fileURL(for: stableId), options: .atomic)
            memory.setObject(image, forKey: stableId as NSString)
            return image
        }
        inFlight[stableId] = fetch
        let image = await fetch.value
        inFlight[stableId] = nil
        return image
    }

    func removeCover(for stableId: String) {
        memory.removeObject(forKey: stableId as NSString)
        try? FileManager.default.removeItem(at: fileURL(for: stableId))
    }
}
