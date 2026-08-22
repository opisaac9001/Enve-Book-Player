@preconcurrency import CarPlay

@MainActor
protocol CarPlayPage: AnyObject {
    var template: CPListTemplate { get }
    func willAppear()
}
