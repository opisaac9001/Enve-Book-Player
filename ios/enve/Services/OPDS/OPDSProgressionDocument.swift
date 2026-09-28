import Foundation

/// The `device` object of an OPDS Progression 1.0 (draft) Progression Document.
nonisolated struct OPDSProgressionDevice: Codable, Equatable, Sendable {
    /// A URI. Enve sends `urn:uuid:<device uuid>`.
    let id: String
    let name: String
}

/// Preserve raw references for round-tripping; point exposes the resolved position.
nonisolated struct OPDSProgressionDocument: Equatable, Sendable {
    let title: String?
    let modified: Date
    let device: OPDSProgressionDevice
    let progression: Double
    let references: [String]

    init(
        title: String? = nil,
        modified: Date,
        device: OPDSProgressionDevice,
        progression: Double,
        references: [String] = []
    ) {
        self.title = title
        self.modified = modified
        self.device = device
        self.progression = min(max(progression, 0), 1)
        self.references = references
    }

    var point: OPDSProgressionPoint { OPDSProgressionPoint(references: references) }
}

/// Validate required members, device name, progression bounds, and URI fields against the draft schema.
extension OPDSProgressionDocument: Codable {
    private enum CodingKeys: String, CodingKey {
        case title, modified, device, progression, references
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        title = try container.decodeIfPresent(String.self, forKey: .title)

        let timestamp = try container.decode(String.self, forKey: .modified)
        guard let modified = ISO8601Timestamp.parse(timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .modified,
                in: container,
                debugDescription: "modified is not an ISO 8601 date and time"
            )
        }
        self.modified = modified

        let device = try container.decode(OPDSProgressionDevice.self, forKey: .device)
        guard !device.name.isEmpty, OPDSProgressionURI.isURI(device.id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .device,
                in: container,
                debugDescription: "device requires a URI id and a non-empty name"
            )
        }
        self.device = device

        let progression = try container.decode(Double.self, forKey: .progression)
        guard progression.isFinite, (0...1).contains(progression) else {
            throw DecodingError.dataCorruptedError(
                forKey: .progression,
                in: container,
                debugDescription: "progression must be a number between 0 and 1"
            )
        }
        self.progression = progression

        let references = try container.decodeIfPresent([String].self, forKey: .references) ?? []
        guard references.allSatisfy(OPDSProgressionURI.isReference) else {
            throw DecodingError.dataCorruptedError(
                forKey: .references,
                in: container,
                debugDescription: "every reference must be a URI reference"
            )
        }
        self.references = references
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(Self.timestamp(modified), forKey: .modified)
        try container.encode(device, forKey: .device)
        try container.encode(progression, forKey: .progression)
        if !references.isEmpty {
            try container.encode(references, forKey: .references)
        }
    }

    /// Sub-second precision is what keeps two devices that write inside the same second orderable.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// The RFC 7807 payload OPDS Progression 1.0 (draft) requires on every failure other than `401`.
nonisolated struct OPDSProblemDetails: Decodable, Equatable, Sendable {
    /// Identifiers the draft asks implementations to use.
    enum Registry: String, Sendable {
        case invalidPayload = "https://registry.opds.io/error#progression-invalid-payload"
        case incorrectUser = "https://registry.opds.io/error#progression-incorrect-user"
        case locked = "https://registry.opds.io/error#progression-locked"
        case staleDate = "https://registry.opds.io/error#progression-date"
    }

    let type: String
    let title: String
    let detail: String?

    var registry: Registry? { Registry(rawValue: type) }

    nonisolated var message: String {
        guard let detail, !detail.isEmpty else { return title }
        return "\(title) \(detail)"
    }
}
