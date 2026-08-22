import Combine
@preconcurrency import CoreMotion
import Foundation
import Logging

final class ShakeDetectionService: @unchecked Sendable {
    static let shared = ShakeDetectionService()

    let shakeDetected = PassthroughSubject<Void, Never>()

    var isMonitoring: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isMonitoring
    }

    private let lock = NSLock()

    #if canImport(UIKit)
    private let motionManager = CMMotionManager()
    private let operationQueue = OperationQueue()
    #endif

    private let accelerationThreshold: Double = 2.5
    private let shakeCountThreshold = 2
    private let shakeTimeWindow: TimeInterval = 0.5
    private let minTimeBetweenNotifications: TimeInterval = 1.0

    private var _isMonitoring = false
    private var shakeEvents: [Date] = []
    private var lastShakeNotification: Date?

    private init() {
        #if canImport(UIKit)
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.name = "com.enve.shakedetection"
        #endif
    }

    func startMonitoring() {
        lock.lock()
        guard !_isMonitoring else { lock.unlock(); return }
        _isMonitoring = true
        lock.unlock()

        #if canImport(UIKit)
        guard motionManager.isAccelerometerAvailable else {
            AppLogger.network.warning("Accelerometer not available on this device")
            lock.lock()
            _isMonitoring = false
            lock.unlock()
            return
        }

        motionManager.accelerometerUpdateInterval = 0.05

        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let data = data, error == nil else { return }
            self?.processAccelerometerData(data)
        }
        #endif

        AppLogger.network.info("Shake detection started")
    }

    func stopMonitoring() {
        lock.lock()
        guard _isMonitoring else { lock.unlock(); return }
        _isMonitoring = false
        shakeEvents.removeAll()
        lastShakeNotification = nil
        lock.unlock()

        #if canImport(UIKit)
        motionManager.stopAccelerometerUpdates()
        #endif

        AppLogger.network.info("Shake detection stopped")
    }

    private func processAccelerometerData(_ data: CMAccelerometerData) {
        let a = data.acceleration
        let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        guard magnitude > accelerationThreshold else { return }

        let now = Date()

        lock.lock()
        shakeEvents.append(now)
        shakeEvents = shakeEvents.filter { now.timeIntervalSince($0) < shakeTimeWindow }

        guard shakeEvents.count >= shakeCountThreshold else { lock.unlock(); return }

        if let last = lastShakeNotification, now.timeIntervalSince(last) < minTimeBetweenNotifications {
            lock.unlock()
            return
        }

        lastShakeNotification = now
        shakeEvents.removeAll()
        lock.unlock()

        shakeDetected.send()
        AppLogger.network.info("Shake detected!")
    }
}
