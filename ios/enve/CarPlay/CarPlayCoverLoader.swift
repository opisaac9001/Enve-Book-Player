@preconcurrency import CarPlay
import Foundation
import UIKit

extension CPListItem {
    @MainActor
    func setCarPlayCover(for book: Book) {
        guard let coverURL = book.coverURL else { return }

        if let cached = DiskImageCache.shared.memoryImage(for: coverURL) {
            setImage(CarPlayCoverLoader.resize(cached))
            return
        }

        Task { [weak self] in
            guard let image = await CarPlayCoverLoader.load(coverURL) else { return }
            self?.setImage(CarPlayCoverLoader.resize(image))
        }
    }

    @MainActor
    func applyDownloadStateBadge(isDownloaded: Bool) {
        guard !isDownloaded else { return }
        setAccessoryImage(UIImage(systemName: "icloud"))
    }
}

enum CarPlayCoverLoader {

    static func load(_ url: URL) async -> UIImage? {
        if let cached = await DiskImageCache.shared.image(for: url) {
            return cached
        }
        let data: Data
        if url.isFileURL {
            guard
                let fileData = try? await Task.detached(
                    priority: .utility,
                    operation: {
                        try Data(contentsOf: url)
                    }
                ).value
            else { return nil }
            data = fileData
        } else {
            guard let (fetched, _) = try? await URLSession.shared.data(from: url) else { return nil }
            data = fetched
        }
        guard let image = UIImage(data: data) else { return nil }
        DiskImageCache.shared.save(image, for: url)
        return image
    }

    nonisolated static func resize(_ image: UIImage) -> UIImage {
        let size = CGSize(width: 90, height: 90)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
