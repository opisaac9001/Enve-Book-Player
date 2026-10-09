@preconcurrency import CarPlay
import Foundation
import Logging
import UIKit

@objc(CarPlaySceneDelegate)
public final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var controller: CarPlayController?
    private var profileObserver: NSObjectProtocol?

    @objc public func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        AppLogger.carplay.info("[CarPlay] Connected")

        profileObserver = NotificationCenter.default.addObserver(forName: .profileSystemAccessChanged, object: nil, queue: .main) { [weak self] notification in
            let session = notification.object as? ProfileSession
            Task { @MainActor in self?.showProfile(session) }
        }
        let coordinator = ProfileSwitchCoordinator.shared
        showProfile(coordinator.isLocked ? nil : coordinator.activeSession)
    }

    @objc public func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        controller?.invalidate()
        if let profileObserver { NotificationCenter.default.removeObserver(profileObserver) }
        profileObserver = nil
        self.interfaceController = nil
        controller = nil
        AppLogger.carplay.info("[CarPlay] Disconnected")
    }
    private func showProfile(_ session: ProfileSession?) {
        controller?.invalidate()
        controller = nil
        guard let interfaceController else { return }
        guard let session, session.isOwner, !session.isRetired else {
            let template = CPListTemplate(title: "Enve", sections: [])
            template.emptyViewTitleVariants = ["Open Enve on your iPhone"]
            interfaceController.setRootTemplate(template, animated: false, completion: nil)
            return
        }
        controller = CarPlayController(interfaceController: interfaceController, environment: .live(profileSession: session))
        controller?.start()
    }

}
