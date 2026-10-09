#if os(iOS)
import SwiftUI
import UIKit

private struct HearthInteractiveBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restoreGesture()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var gesture: UIGestureRecognizer?
        private weak var previousDelegate: (any UIGestureRecognizerDelegate)?
        private var previousEnabled = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let navigationController,
                navigationController.viewControllers.count > 1,
                let gesture = navigationController.interactivePopGestureRecognizer,
                gesture.delegate !== self
            else { return }
            self.gesture = gesture
            if let owner = gesture.delegate as? Controller {
                previousDelegate = owner.previousDelegate
                previousEnabled = owner.previousEnabled
            } else {
                previousDelegate = gesture.delegate
                previousEnabled = gesture.isEnabled
            }
            gesture.delegate = self
            gesture.isEnabled = true
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            restoreGesture()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigationController else { return false }
            return navigationController.viewControllers.count > 1
                && navigationController.transitionCoordinator == nil
                && view.window != nil
        }

        func restoreGesture() {
            guard let gesture, gesture.delegate === self else { return }
            gesture.delegate = previousDelegate
            gesture.isEnabled = previousEnabled
            self.gesture = nil
            previousDelegate = nil
        }
    }
}

extension View {
    func hearthInteractiveBack() -> some View {
        background(HearthInteractiveBack().frame(width: 0, height: 0))
    }
}
#endif
