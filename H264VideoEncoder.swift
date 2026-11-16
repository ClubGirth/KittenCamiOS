import CoreMedia
import Foundation
import VideoToolbox

final class H264VideoEncoder: @unchecked Sendable {
    var onVideoConfiguration: ((Data) -> Void)?
    var onVideoFrame: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    private let encoderQueue = DispatchQueue(
        label: "com.zakk.KittenCam.h264-encoder",
        qos: .userInteractive
    )

    private var compressionSession: VTCompressionSession?
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0
    private var frameRate: Int32 = 30
    private var bitrate: Int = 4_000_000
    private var lastConfigurationData: Data?

    deinit {
        invalidate()
    }

    func encode(
        sampleBuffer: CMSampleBuffer,
        targetFrameRate: Int,
        targetBitrate: Int? = nil
    ) {
        encoderQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.encodeOnQueue(
                sampleBuffer: sampleBuffer,
                targetFrameRate: targetFrameRate,
                targetBitrate: targetBitrate
            )
        }
    }

    func invalidate() {
        encoderQueue.sync {
            invalidateOnQueue()
        }
    }

    private func encodeOnQueue(
        sampleBuffer: CMSampleBuffer,
        targetFrameRate: Int,
        targetBitrate: Int?
    ) {
        guard let imageBuffer =
                CMSampleBufferGetImageBuffer(
                    sampleBuffer
                ) else {
            reportError(
                "The camera frame did not contain a pixel buffer."
            )
            return
        }

        let width = Int32(
            CVPixelBufferGetWidth(imageBuffer)
        )

        let height = Int32(
            CVPixelBufferGetHeight(imageBuffer)
        )

        let requestedFrameRate =
            Int32(max(targetFrameRate, 1))

        let requestedBitrate =
            targetBitrate ??
            recommendedBitrate(
                width: width,
                height: height,
                fps: requestedFrameRate
            )

        if compressionSession == nil ||
            width != currentWidth ||
            height != currentHeight ||
            requestedFrameRate != frameRate ||
            requestedBitrate != bitrate {

            do {
                try createCompressionSession(
                    width: width,
                    height: height,
                    fps: requestedFrameRate,
                    bitrate: requestedBitrate
                )
            } catch {
                reportError(
                    "The H.264 encoder could not start: \(error.localizedDescription)"
                )
                return
            }
        }

        guard let compressionSession else {
            reportError(
                "The H.264 encoder is unavailable."
            )
            return
        }

        let presentationTimeStamp =
            CMSampleBufferGetPresentationTimeStamp(
                sampleBuffer
            )

        let duration =
            CMSampleBufferGetDuration(
                sampleBuffer
            )

        let frameProperties: CFDictionary? = nil
        var flags = VTEncodeInfoFlags()

        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp:
                presentationTimeStamp,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )

        guard status == noErr else {
            reportError(
                "H.264 frame encoding failed with status \(status)."
            )
            return
        }
    }

    private func createCompressionSession(
        width: Int32,
        height: Int32,
        fps: Int32,
        bitrate: Int
    ) throws {
        invalidateOnQueue()

        var newSession:
            VTCompressionSession?

        let callback:
            VTCompressionOutputCallback = {
                outputCallbackRefCon,
                _,
                status,
                infoFlags,
                sampleBuffer in

                guard
                    status == noErr,
                    !infoFlags.contains(
                        .frameDropped
                    ),
                    let sampleBuffer,
                    let outputCallbackRefCon
                else {
                    return
                }

                let encoder =
                    Unmanaged<H264VideoEncoder>
                        .fromOpaque(
                            outputCallbackRefCon
                        )
                        .takeUnretainedValue()

                encoder.handleEncodedSampleBuffer(
                    sampleBuffer
                )
            }

        let status =
            VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: width,
                height: height,
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: callback,
                refcon:
                    Unmanaged.passUnretained(
                        self
                    ).toOpaque(),
                compressionSessionOut:
                    &newSession
            )

        guard
            status == noErr,
            let newSession
        else {
            throw EncoderError.sessionCreationFailed(
                status
            )
        }

        compressionSession = newSession
        currentWidth = width
        currentHeight = height
        frameRate = fps
        self.bitrate = bitrate
        lastConfigurationData = nil

        try setProperty(
            session: newSession,
            key:
                kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )

        try setProperty(
            session: newSession,
            key:
                kVTCompressionPropertyKey_ProfileLevel,
            value:
                kVTProfileLevel_H264_Main_AutoLevel
        )

        try setProperty(
            session: newSession,
            key:
                kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )

        try setProperty(
            session: newSession,
            key:
                kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: fps)
        )

        try setProperty(
            session: newSession,
            key:
                kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitrate)
        )

        let bytesPerSecond =
            max(bitrate / 8, 1)

        let dataRateLimits: CFArray = [
            NSNumber(value: bytesPerSecond),
            NSNumber(value: 1)
        ] as CFArray

        try setProperty(
            session: newSession,
            key:
                kVTCompressionPropertyKey_DataRateLimits,
            value: dataRateLimits
        )

        try setProperty(
            session: newSession,
            key:
                kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(
                value: max(fps * 2, 1)
            )
        )

        try setProperty(
            session: newSession,
            key:
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: 2)
        )

        let prepareStatus =
            VTCompressionSessionPrepareToEncodeFrames(
                newSession
            )

        guard prepareStatus == noErr else {
            throw EncoderError.prepareFailed(
                prepareStatus
            )
        }

        print(
            "KittenCam H.264 encoder ready: \(width)×\(height), \(fps) FPS, \(bitrate) bps"
        )
    }

    private func setProperty(
        session: VTCompressionSession,
        key: CFString,
        value: CFTypeRef
    ) throws {
        let status =
            VTSessionSetProperty(
                session,
                key: key,
                value: value
            )

        guard status == noErr else {
            throw EncoderError.propertyFailed(
                key as String,
                status
            )
        }
    }

    private func handleEncodedSampleBuffer(
        _ sampleBuffer: CMSampleBuffer
    ) {
        guard
            CMSampleBufferDataIsReady(
                sampleBuffer
            )
        else {
            return
        }

        let isKeyFrame =
            sampleBufferIsKeyFrame(
                sampleBuffer
            )

        /*
         Send SPS/PPS before every keyframe.

         A desktop client may connect after the encoder has already
         started. Repeating the configuration here guarantees that a
         newly connected client can begin decoding at the next keyframe.
        */
        if isKeyFrame,
           let formatDescription =
                CMSampleBufferGetFormatDescription(
                    sampleBuffer
                ),
           let configurationData =
                makeConfigurationData(
                    from: formatDescription
                ) {

            lastConfigurationData =
                configurationData

            onVideoConfiguration?(
                configurationData
            )
        }

        guard let annexBData =
                makeAnnexBData(
                    from: sampleBuffer
                ) else {
            reportError(
                "The encoded H.264 frame could not be packetized."
            )
            return
        }

        let presentationTimeStamp =
            CMSampleBufferGetPresentationTimeStamp(
                sampleBuffer
            )

        let microseconds =
            presentationTimeStamp.isValid
            ? max(
                Int64(
                    CMTimeGetSeconds(
                        presentationTimeStamp
                    ) * 1_000_000
                ),
                0
            )
            : 0

        var payload = Data()
        payload.reserveCapacity(
            9 + annexBData.count
        )

        payload.append(
            isKeyFrame ? 1 : 0
        )

        var networkTimestamp =
            UInt64(microseconds).bigEndian

        withUnsafeBytes(
            of: &networkTimestamp
        ) {
            payload.append(
                contentsOf: $0
            )
        }

        payload.append(annexBData)

        onVideoFrame?(payload)
    }

    private func sampleBufferIsKeyFrame(
        _ sampleBuffer: CMSampleBuffer
    ) -> Bool {
        guard
            let attachments =
                CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer,
                    createIfNecessary: false
                ) as? [[CFString: Any]],
            let firstAttachment =
                attachments.first
        else {
            return true
        }

        return firstAttachment[
            kCMSampleAttachmentKey_NotSync
        ] == nil
    }

    /*
     Configuration payload format:

     4 bytes: SPS length, big-endian
     N bytes: SPS
     4 bytes: PPS length, big-endian
     N bytes: PPS
    */
    private func makeConfigurationData(
        from formatDescription:
            CMFormatDescription
    ) -> Data? {
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0

        let countStatus =
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut:
                    &parameterSetCount,
                nalUnitHeaderLengthOut:
                    &nalUnitHeaderLength
            )

        guard
            countStatus == noErr,
            parameterSetCount >= 2
        else {
            return nil
        }

        guard
            let sps = parameterSet(
                at: 0,
                from: formatDescription
            ),
            let pps = parameterSet(
                at: 1,
                from: formatDescription
            )
        else {
            return nil
        }

        var payload = Data()

        appendLengthPrefixed(
            sps,
            to: &payload
        )

        appendLengthPrefixed(
            pps,
            to: &payload
        )

        return payload
    }

    private func parameterSet(
        at index: Int,
        from formatDescription:
            CMFormatDescription
    ) -> Data? {
        var pointer:
            UnsafePointer<UInt8>?

        var size = 0

        let status =
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut:
                    &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )

        guard
            status == noErr,
            let pointer,
            size > 0
        else {
            return nil
        }

        return Data(
            bytes: pointer,
            count: size
        )
    }

    private func appendLengthPrefixed(
        _ data: Data,
        to payload: inout Data
    ) {
        var networkLength =
            UInt32(data.count).bigEndian

        withUnsafeBytes(
            of: &networkLength
        ) {
            payload.append(
                contentsOf: $0
            )
        }

        payload.append(data)
    }

    /*
     Converts AVCC length-prefixed NAL units to Annex-B:

     00 00 00 01 + NAL
    */
    private func makeAnnexBData(
        from sampleBuffer:
            CMSampleBuffer
    ) -> Data? {
        guard let dataBuffer =
                CMSampleBufferGetDataBuffer(
                    sampleBuffer
                ) else {
            return nil
        }

        var totalLength = 0
        var dataPointer:
            UnsafeMutablePointer<Int8>?

        let status =
            CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut:
                    &totalLength,
                dataPointerOut:
                    &dataPointer
            )

        guard
            status == kCMBlockBufferNoErr,
            let dataPointer,
            totalLength > 0
        else {
            return nil
        }

        let bytes = UnsafeRawPointer(
            dataPointer
        ).assumingMemoryBound(
            to: UInt8.self
        )

        var offset = 0
        var annexB = Data()
        let startCode:
            [UInt8] = [0, 0, 0, 1]

        while offset + 4 <= totalLength {
            let nalLength =
                Int(bytes[offset]) << 24 |
                Int(bytes[offset + 1]) << 16 |
                Int(bytes[offset + 2]) << 8 |
                Int(bytes[offset + 3])

            offset += 4

            guard
                nalLength > 0,
                offset + nalLength <=
                    totalLength
            else {
                return nil
            }

            annexB.append(
                contentsOf: startCode
            )

            annexB.append(
                bytes + offset,
                count: nalLength
            )

            offset += nalLength
        }

        return offset == totalLength
            ? annexB
            : nil
    }

    private func recommendedBitrate(
        width: Int32,
        height: Int32,
        fps: Int32
    ) -> Int {
        let pixels =
            Int(width) * Int(height)

        let baseBitrate: Int

        switch pixels {
        case ..<1_000_000:
            baseBitrate = 2_000_000

        case ..<2_500_000:
            baseBitrate = 4_000_000

        case ..<5_000_000:
            baseBitrate = 7_000_000

        default:
            baseBitrate = 12_000_000
        }

        if fps > 30 {
            return Int(
                Double(baseBitrate) * 1.5
            )
        }

        return baseBitrate
    }

    private func invalidateOnQueue() {
        guard let compressionSession else {
            return
        }

        VTCompressionSessionCompleteFrames(
            compressionSession,
            untilPresentationTimeStamp:
                .invalid
        )

        VTCompressionSessionInvalidate(
            compressionSession
        )

        self.compressionSession = nil
        currentWidth = 0
        currentHeight = 0
        lastConfigurationData = nil
    }

    private func reportError(
        _ message: String
    ) {
        print(message)
        onError?(message)
    }
}

private enum EncoderError:
    LocalizedError {

    case sessionCreationFailed(OSStatus)
    case propertyFailed(String, OSStatus)
    case prepareFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(
            let status
        ):
            return "Compression session creation failed with status \(status)."

        case .propertyFailed(
            let property,
            let status
        ):
            return "Setting \(property) failed with status \(status)."

        case .prepareFailed(let status):
            return "Preparing the encoder failed with status \(status)."
        }
    }
}
