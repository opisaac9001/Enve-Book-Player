import SwiftUI

struct HearthTabStack<Content: View>: View {
    let isActive: Bool
    let resetToken: UUID?
    @ViewBuilder let content: () -> Content

    var body: some View {
        // Defer navigation construction to a child body so keyboard updates have enough stack space.
        NavigationStack {
            content()
                .clearsNavigationContainerBackground()
                .accessibilityHidden(!isActive)
        }
        .id(resetToken)
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
    }
}
