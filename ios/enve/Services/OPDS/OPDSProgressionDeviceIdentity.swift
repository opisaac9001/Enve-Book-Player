import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Use a persisted installation UUID; identifierForVendor can change when the last Enve app is removed.
enum OPDSProgressionDeviceIdentity {
    static var current: OPDSProgressionDevice {
        OPDSProgressionDevice(id: identifier, name: displayName)
    }

    private static var identifier: String {
        let stored = StorageService.shared.loadDeviceUUID()
        let canonical = UUID(uuidString: stored)?.uuidString.lowercased() ?? stored.lowercased()
        return "urn:uuid:\(canonical)"
    }

    private static var displayName: String {
        #if canImport(UIKit)
        let device = UIDevice.current.name
        return device.isEmpty ? "Enve" : "Enve (\(device))"
        #else
        guard let host = Host.current().localizedName, !host.isEmpty else { return "Enve" }
        return "Enve (\(host))"
        #endif
    }
}
