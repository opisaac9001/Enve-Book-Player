import Foundation

struct DiscoverBook: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let title: String
    let author: String
    let narrator: String?
    let artworkURL: String
    let description: String?
    let releaseDate: Date?
    let genre: String?
    let duration: TimeInterval?
    let price: Double?
    let currency: String?
    let storeURL: String?
    let previewURL: String?
    let collectionId: Int

    var highResArtworkURL: URL? {
        let hiRes =
            artworkURL
            .replacingOccurrences(of: "100x100bb", with: "600x600bb")
            .replacingOccurrences(of: "60x60bb", with: "600x600bb")
        return URL(string: hiRes)
    }

    var artworkImageURL: URL? {
        URL(string: artworkURL)
    }

    var formattedDuration: String? {
        guard let duration = duration else { return nil }
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var releaseYear: String? {
        guard let date = releaseDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: date)
    }

    var formattedPrice: String? {
        guard let price = price, let currency = currency else { return nil }
        if price == 0 { return "Free" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: price))
    }

    var shortDescription: String? {
        guard let description, !description.isEmpty else { return nil }
        return description.replacingOccurrences(of: "\n", with: " ")
    }
}

struct DiscoverSection: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    var books: [DiscoverBook]

    static func == (lhs: DiscoverSection, rhs: DiscoverSection) -> Bool {
        lhs.id == rhs.id && lhs.books == rhs.books
    }
}
