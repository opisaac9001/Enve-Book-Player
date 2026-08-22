#if os(iOS)
import Foundation
import ReplayKit
import CoreMedia
import CoreVideo
import Logging

@MainActor
final class CompanionScreenCapture {
    private let recorder = RPScreenRecorder.shared()
    private(set) var isCapturing = false

    var onVideoFrame: ((CVPixelBuffer, CMTime) -> Void)?

    func start() async -> Bool {
        guard !isCapturing else { return true }
        guard recorder.isAvailable else {
            AppLogger.network.warning("[CompanionCapture] screen recording unavailable")
            return false
        }
        recorder.isMicrophoneEnabled = false
        recorder.isCameraEnabled = false

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                recorder.startCapture { [weak self] sampleBuffer, bufferType, error in
                    guard error == nil, bufferType == .video else { return }
                    guard let self,
                        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                    else { return }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    Task { @MainActor [weak self] in
                        self?.onVideoFrame?(pixelBuffer, pts)
                    }
                } completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            isCapturing = true
            AppLogger.network.info("[CompanionCapture] screen capture started")
            return true
        } catch {
            AppLogger.network.warning("[CompanionCapture] start failed: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        guard isCapturing else { return }
        isCapturing = false
        onVideoFrame = nil
        recorder.stopCapture()
        AppLogger.network.info("[CompanionCapture] screen capture stopped")
    }
}
#endif
