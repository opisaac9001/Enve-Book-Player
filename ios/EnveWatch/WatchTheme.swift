import SwiftUI

enum WatchTheme {
    static let ember = Color(red: 0.961, green: 0.573, blue: 0.102)
    static let emberDim = ember.opacity(0.35)

    static func timeString(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "0:00" }
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func remainingString(position: TimeInterval, duration: TimeInterval) -> String {
        guard duration > position else { return "Finished" }
        let remaining = duration - position
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m left"
        }
        return "\(minutes)m left"
    }

    static func sizeString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension View {
    func watchSerifTitle() -> some View {
        fontDesign(.serif)
    }
}
