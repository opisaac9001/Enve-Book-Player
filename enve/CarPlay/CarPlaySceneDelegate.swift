@preconcurrency import CarPlay
import Foundation
import Logging
import UIKit

@objc(CarPlaySceneDelegate)
public final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var controller: CarPlayController?

    @objc public func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        AppLogger.carplay.info("[CarPlay] Connected")

        if controller == nil {
            controller = CarPlayController(interfaceController: interfaceController, environment: .live())
            controller?.start()
        }
    }

    @objc public func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        controller?.invalidate()
        self.interfaceController = nil
        controller = nil
        AppLogger.carplay.info("[CarPlay] Disconnected")
    }
}
