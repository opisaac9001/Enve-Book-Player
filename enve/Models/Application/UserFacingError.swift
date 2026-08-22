import Foundation

struct UserFacingError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}
