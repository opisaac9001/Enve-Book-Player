import CoreMedia
import CoreVideo
import Foundation
import Logging
import VideoToolbox

nonisolated final class CompanionVideoEncoder: @unchecked Sendable {

    struct AccessUnit: Sendable {
        let data: Data
        let isKeyframe: Bool
        let ptsMillis: Int64
    }

    var onAccessUnit: (@Sendable (AccessUnit) -> Void)?

    private var session: VTCompressionSession?
    private var streamStart: CMTime?
    private let width: Int32
    private let height: Int32

    private static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    init(width: Int, height: Int) {
        self.width = Int32(width)
        self.height = Int32(height)
    }

    deinit {
        stop()
    }

    func start() -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            AppLogger.network.error("[CompanionVideo] VTCompressionSession create failed (\(status))")
            return false
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 6_000_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)

        self.session = session
        self.streamStart = nil
        AppLogger.network.info("[CompanionVideo] Encoder started \(self.width)×\(self.height)")
        return true
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        self.streamStart = nil
    }

    func requestKeyframe() {

        forceNextKeyframe = true
    }

    private var forceNextKeyframe = false

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }

        var properties: [CFString: Any]?
        if forceNextKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!]
            forceNextKeyframe = false
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: properties as CFDictionary?,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            self.handleEncoded(sampleBuffer)
        }
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
            let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if streamStart == nil { streamStart = pts }
        let elapsed = pts - (streamStart ?? pts)
        let ptsMillis = Int64(CMTimeGetSeconds(elapsed) * 1000)

        let isKeyframe = Self.isKeyframe(sampleBuffer)

        var annexB = Data()

        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for paramSet in Self.parameterSets(from: formatDesc) {
                annexB.append(Self.startCode)
                annexB.append(paramSet)
            }
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard
            CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            ) == noErr, let dataPointer
        else { return }

        var offset = 0
        let avccHeaderLength = 4
        while offset + avccHeaderLength <= totalLength {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, dataPointer + offset, avccHeaderLength)
            nalLength = CFSwapInt32BigToHost(nalLength)
            let nalStart = offset + avccHeaderLength
            guard nalStart + Int(nalLength) <= totalLength else { break }
            annexB.append(Self.startCode)
            annexB.append(Data(bytes: dataPointer + nalStart, count: Int(nalLength)))
            offset = nalStart + Int(nalLength)
        }

        onAccessUnit?(AccessUnit(data: annexB, isKeyframe: isKeyframe, ptsMillis: ptsMillis))
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
            CFArrayGetCount(attachments) > 0
        else {
            return true
        }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()

        return !CFDictionaryContainsKey(dict, key)
    }

    private static func parameterSets(from formatDesc: CMFormatDescription) -> [Data] {
        var count = 0
        guard
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            ) == noErr
        else { return [] }

        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return sets
    }
}
