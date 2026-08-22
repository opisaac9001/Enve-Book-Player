import CoreGraphics
import Foundation

public enum CompanionService {
    public static let bonjourType = "_enveread._tcp"
    public static let bonjourDomain = "local."

    public static let txtRecordKeys = TxtRecord()

    public struct TxtRecord {
        public let bookTitle = "book"
        public let deviceName = "device"
        public let protocolVersion = "v"
    }
}

public enum CompanionMessageType: String, Codable, Sendable {

    case sessionStart
    case pageFrame
    case highlightUpdate
    case mediaOverlayState
    case sessionEnd

    case videoStreamStart

    case videoFrame

    case videoStreamStop

    case pageCommand
    case viewportInfo
    case readAloudCommand

    case ping
    case pong
}

public struct CompanionMessageEnvelope: Codable, Sendable {
    public let type: CompanionMessageType
    public let payloadJSON: Data
    public let timestamp: Double

    public init(type: CompanionMessageType, payloadJSON: Data, timestamp: Double = Date().timeIntervalSince1970) {
        self.type = type
        self.payloadJSON = payloadJSON
        self.timestamp = timestamp
    }
}

public struct SessionStartPayload: Codable, Sendable {
    public let bookTitle: String
    public let bookStableId: String
    public let deviceName: String
    public let pageSize: PageSize
    public let hasMediaOverlay: Bool
    public let protocolVersion: Int

    public init(
        bookTitle: String,
        bookStableId: String,
        deviceName: String,
        pageSize: PageSize,
        hasMediaOverlay: Bool,
        protocolVersion: Int = 1
    ) {
        self.bookTitle = bookTitle
        self.bookStableId = bookStableId
        self.deviceName = deviceName
        self.pageSize = pageSize
        self.hasMediaOverlay = hasMediaOverlay
        self.protocolVersion = protocolVersion
    }
}

public struct PageSize: Codable, Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct PageFramePayload: Codable, Sendable {
    public let pageIndex: Int
    public let totalPages: Int
    public let imageByteCount: Int
    public let chapterTitle: String?

    public init(pageIndex: Int, totalPages: Int, imageByteCount: Int, chapterTitle: String? = nil) {
        self.pageIndex = pageIndex
        self.totalPages = totalPages
        self.imageByteCount = imageByteCount
        self.chapterTitle = chapterTitle
    }
}

public struct VideoStreamStartPayload: Codable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct VideoFramePayload: Codable, Sendable {
    public let byteCount: Int
    public let isKeyframe: Bool

    public let ptsMillis: Int64

    public init(byteCount: Int, isKeyframe: Bool, ptsMillis: Int64) {
        self.byteCount = byteCount
        self.isKeyframe = isKeyframe
        self.ptsMillis = ptsMillis
    }
}

public struct HighlightPayload: Codable, Sendable, Equatable {
    public let pageIndex: Int
    public let normalizedRect: NormalizedRect

    public init(pageIndex: Int, normalizedRect: NormalizedRect) {
        self.pageIndex = pageIndex
        self.normalizedRect = normalizedRect
    }
}

public struct NormalizedRect: Codable, Sendable, Equatable {
    public let minX: Double
    public let minY: Double
    public let width: Double
    public let height: Double

    public init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }

    public var midX: Double { minX + width / 2 }
    public var midY: Double { minY + height / 2 }

    public init(rect: CGRect, in pageSize: CGSize) {
        guard pageSize.width > 0 && pageSize.height > 0 else {
            self.init(minX: 0, minY: 0, width: 0, height: 0)
            return
        }
        self.init(
            minX: Double(rect.minX / pageSize.width),
            minY: Double(rect.minY / pageSize.height),
            width: Double(rect.width / pageSize.width),
            height: Double(rect.height / pageSize.height)
        )
    }
}

public struct MediaOverlayStatePayload: Codable, Sendable {
    public let isPlaying: Bool

    public let speed: Double?

    public init(isPlaying: Bool, speed: Double? = nil) {
        self.isPlaying = isPlaying
        self.speed = speed
    }
}

public struct SessionEndPayload: Codable, Sendable {
    public let reason: Reason

    public enum Reason: String, Codable, Sendable {
        case userClosedReader
        case deviceWentToBackground
        case error
    }

    public init(reason: Reason) {
        self.reason = reason
    }
}

public struct PageCommandPayload: Codable, Sendable {
    public enum Direction: String, Codable, Sendable {
        case next
        case previous
    }

    public let direction: Direction

    public init(direction: Direction) {
        self.direction = direction
    }
}

public struct ReadAloudCommandPayload: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case togglePlay
        case nextClip
        case previousClip
        case cycleSpeed
    }

    public let action: Action

    public init(action: Action) {
        self.action = action
    }
}

public struct ViewportInfoPayload: Codable, Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var aspectRatio: Double {
        height > 0 ? width / height : 1.0
    }
}

public struct EmptyPayload: Codable, Sendable {
    public init() {}
}
