import Foundation

enum StoryAlignAvailability {
    static var unsupportedTitle: String {
        "Update Required"
    }

    static var unsupportedMessage: String {
        "StoryAlign requires iOS 26.0 or newer."
    }

    static var isSupported: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }
}
