import AVFoundation
import Combine
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Network
import VideoToolbox

struct ControlStreamInformation: Decodable, Equatable {
    let protocolVersion: UInt8?
    let deviceName: String?
    let streamType: String?
    let encodedWidth: Int?
    let encodedHeight: Int?
    let displayWidth: Int?
    let displayHeight: Int?
    let fps: Int?
    let orientation: String?
    let deviceOrientation: String?
    let videoOrientation: String?
    let encodedOrientation: String?
    let rotationDegrees: Int?
    let rotationDegreesClockwise: Int?
    let displayRotationDegrees: Int?
    let audioEnabled: Bool?
    let audioCodec: String?
    let audioSampleRate: Double?
    let audioChannels: Int?
    let audioBitsPerChannel: Int?
}

struct ControlAudioConfiguration: Decodable, Equatable {
    let codec: String?
    let format: String?
    let sampleRate: Double
    let channels: Int
    let bitsPerChannel: Int
    let bytesPerFrame: Int?
    let interleaved: Bool?
    let isFloat: Bool?
    let isBigEndian: Bool?
    let isSignedInteger: Bool?
}

struct ControlVideoFrame {
    let keyFrame: Bool
    let timestamp: UInt64
    let data: Data
}

struct ControlAudioFrame {
    let timestamp: UInt64
    let sampleCount: UInt32
    let data: Data
}

struct ControlStreamStatistics: Equatable {
    var connected = false
    var receivedBytes = 0
    var packets = 0
    var videoFrames = 0
    var audioFrames = 0
    var heartbeats = 0
    var decodedFrames = 0
    var droppedFrames = 0
}

final class ControlPacketParser {
    var onStreamInformation: ((ControlStreamInformation) -> Void)?
    var onVideoConfiguration: ((Data) -> Void)?
    var onVideoFrame: ((ControlVideoFrame) -> Void)?
    var onAudioConfiguration: ((ControlAudioConfiguration) -> Void)?
    var onAudioFrame: ((ControlAudioFrame) -> Void)?
    var onHeartbeat: (() -> Void)?
    var onRemoteError: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let headerSize = 6
    private let protocolVersion: UInt8 = 1
    private let maximumPayloadLength = 64 * 1024 * 1024
    private var buffer = Data()

    private(set) var statistics = ControlStreamStatistics()

    func push(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        statistics.receivedBytes += data.count
        buffer.append(data)
        process()
    }

    func reset() {
        buffer.removeAll(keepingCapacity: false)
    }

    private func process() {
        while buffer.count >= headerSize {
            let version = buffer[buffer.startIndex]
            guard version == protocolVersion else {
                onError?("Unsupported KittenCam protocol version \(version).")
                reset()
                return
            }

            let type = buffer[buffer.startIndex + 1]
            let payloadLength = Int(buffer.readUInt32BE(at: buffer.startIndex + 2))
            guard payloadLength <= maximumPayloadLength else {
                onError?("KittenCam packet payload was too large.")
                reset()
                return
            }

            let totalLength = headerSize + payloadLength
            guard buffer.count >= totalLength else {
                return
            }

            let payloadStart = buffer.startIndex + headerSize
            let payloadEnd = payloadStart + payloadLength
            let payload = Data(buffer[payloadStart..<payloadEnd])
            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
            statistics.packets += 1
            handle(type: type, payload: payload)
        }
    }

    private func handle(type: UInt8, payload: Data) {
        do {
            switch type {
            case KittenCamPacketType.streamInformation.rawValue:
                let information = try JSONDecoder().decode(ControlStreamInformation.self, from: payload)
                onStreamInformation?(information)

            case KittenCamPacketType.videoConfiguration.rawValue:
                onVideoConfiguration?(payload)

            case KittenCamPacketType.videoFrame.rawValue:
                guard payload.count >= 9 else {
                    throw ParserError.invalidVideoFrame
                }

                statistics.videoFrames += 1
                onVideoFrame?(
                    ControlVideoFrame(
                        keyFrame: payload[payload.startIndex] == 1,
                        timestamp: payload.readUInt64BE(at: payload.startIndex + 1),
                        data: Data(payload[(payload.startIndex + 9)..<payload.endIndex])
                    )
                )

            case KittenCamPacketType.heartbeat.rawValue:
                statistics.heartbeats += 1
                onHeartbeat?()

            case KittenCamPacketType.error.rawValue:
                onRemoteError?(String(data: payload, encoding: .utf8) ?? "Remote camera error.")

            case KittenCamPacketType.audioConfiguration.rawValue:
                let configuration = try JSONDecoder().decode(ControlAudioConfiguration.self, from: payload)
                onAudioConfiguration?(configuration)

            case KittenCamPacketType.audioFrame.rawValue:
                guard payload.count >= 12 else {
                    throw ParserError.invalidAudioFrame
                }

                statistics.audioFrames += 1
                onAudioFrame?(
                    ControlAudioFrame(
                        timestamp: payload.readUInt64BE(at: payload.startIndex),
                        sampleCount: payload.readUInt32BE(at: payload.startIndex + 8),
                        data: Data(payload[(payload.startIndex + 12)..<payload.endIndex])
                    )
                )

            default:
                break
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private enum ParserError: LocalizedError {
        case invalidVideoFrame
        case invalidAudioFrame

        var errorDescription: String? {
            switch self {
            case .invalidVideoFrame:
                return "The video packet was too small."
            case .invalidAudioFrame:
                return "The audio packet was too small."
            }
        }
    }
}

private extension Data {
    func readUInt32BE(at index: Data.Index) -> UInt32 {
        var value: UInt32 = 0
        for offset in 0..<4 {
            value = (value << 8) | UInt32(self[index + offset])
        }
        return value
    }

    func readUInt64BE(at index: Data.Index) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<8 {
            value = (value << 8) | UInt64(self[index + offset])
        }
        return value
    }
}

final class ControlStreamClient: ObservableObject {
    @Published private(set) var statistics = ControlStreamStatistics()
    @Published private(set) var stateText = "Disconnected"
    @Published private(set) var streamInformation: ControlStreamInformation?
    @Published private(set) var latestImage: CGImage?
    @Published private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.zakk.KittenCam.control-stream")
    private var connection: NWConnection?
    private var heartbeatTimer: DispatchSourceTimer?
    private let parser = ControlPacketParser()
    private let decoder = ControlH264Decoder()
    private let audioPlayer = ControlAudioPlayer()

    init() {
        parser.onStreamInformation = { [weak self] information in
            DispatchQueue.main.async {
                self?.streamInformation = information
                self?.stateText = "Live"
            }
        }

        parser.onVideoConfiguration = { [weak self] payload in
            self?.decoder.configure(with: payload)
        }

        parser.onVideoFrame = { [weak self] frame in
            self?.decoder.decode(frame)
        }

        parser.onAudioConfiguration = { [weak self] configuration in
            self?.audioPlayer.configure(configuration)
        }

        parser.onAudioFrame = { [weak self] frame in
            self?.audioPlayer.enqueue(frame)
        }

        parser.onHeartbeat = { [weak self] in
            self?.restartHeartbeatTimer()
            self?.publishStatistics()
        }

        parser.onRemoteError = { [weak self] message in
            self?.publishError(message)
        }

        parser.onError = { [weak self] message in
            self?.publishError(message)
        }

        decoder.onImage = { [weak self] image in
            DispatchQueue.main.async {
                self?.latestImage = image
                self?.statistics.decodedFrames += 1
            }
        }

        decoder.onDroppedFrame = { [weak self] in
            DispatchQueue.main.async {
                self?.statistics.droppedFrames += 1
            }
        }

        decoder.onError = { [weak self] message in
            self?.publishError(message)
        }
    }

    func connect(to endpoint: ControlCameraEndpoint) {
        disconnect()

        guard let nwEndpoint = endpoint.nwEndpoint else {
            publishError("The video server endpoint is invalid.")
            return
        }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let connection = NWConnection(to: nwEndpoint, using: parameters)
        self.connection = connection

        DispatchQueue.main.async {
            self.stateText = "Connecting..."
            self.lastError = nil
            self.statistics = ControlStreamStatistics()
            self.streamInformation = nil
            self.latestImage = nil
        }

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state)
        }

        connection.start(queue: queue)
    }

    func disconnect() {
        stopHeartbeatTimer()
        connection?.cancel()
        connection = nil
        parser.reset()
        decoder.reset()
        audioPlayer.reset()

        DispatchQueue.main.async {
            self.statistics.connected = false
            self.stateText = "Disconnected"
            self.latestImage = nil
            self.streamInformation = nil
        }
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        audioPlayer.setVolume(enabled ? 1 : 0)
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            DispatchQueue.main.async {
                self.statistics.connected = true
                self.stateText = "Waiting for stream..."
            }
            restartHeartbeatTimer()
            receiveNextChunk()

        case .failed(let error):
            publishError("Video stream failed: \(error.localizedDescription)")
            disconnect()

        case .cancelled:
            DispatchQueue.main.async {
                self.statistics.connected = false
                self.stateText = "Disconnected"
            }

        default:
            break
        }
    }

    private func receiveNextChunk() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.parser.push(data)
                self.publishStatistics()
            }

            if let error {
                self.publishError("Video receive failed: \(error.localizedDescription)")
                self.disconnect()
                return
            }

            if isComplete {
                self.disconnect()
                return
            }

            self.receiveNextChunk()
        }
    }

    private func publishStatistics() {
        let parserStatistics = parser.statistics
        DispatchQueue.main.async {
            self.statistics.receivedBytes = parserStatistics.receivedBytes
            self.statistics.packets = parserStatistics.packets
            self.statistics.videoFrames = parserStatistics.videoFrames
            self.statistics.audioFrames = parserStatistics.audioFrames
            self.statistics.heartbeats = parserStatistics.heartbeats
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async {
            self.lastError = message
            self.stateText = "Error"
        }
    }

    private func restartHeartbeatTimer() {
        stopHeartbeatTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15)
        timer.setEventHandler { [weak self] in
            self?.publishError("Video heartbeat timed out.")
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeatTimer() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
}

final class ControlH264Decoder {
    var onImage: ((CGImage) -> Void)?
    var onDroppedFrame: (() -> Void)?
    var onError: ((String) -> Void)?

    private let decodeQueue = DispatchQueue(label: "com.zakk.KittenCam.control-h264-decoder")
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var waitingForKeyFrame = true

    func configure(with payload: Data) {
        decodeQueue.async { [weak self] in
            self?.configureOnQueue(with: payload)
        }
    }

    func decode(_ frame: ControlVideoFrame) {
        decodeQueue.async { [weak self] in
            self?.decodeOnQueue(frame)
        }
    }

    func reset() {
        decodeQueue.async { [weak self] in
            self?.invalidateOnQueue()
            self?.formatDescription = nil
            self?.waitingForKeyFrame = true
        }
    }

    private func configureOnQueue(with payload: Data) {
        do {
            let sets = try parseConfiguration(payload)
            let sps = sets.sps
            let pps = sets.pps

            let status = sps.withUnsafeBytes { spsBuffer in
                pps.withUnsafeBytes { ppsBuffer in
                    let parameterSetPointers: [UnsafePointer<UInt8>] = [
                        spsBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        ppsBuffer.bindMemory(to: UInt8.self).baseAddress!
                    ]
                    let parameterSetSizes = [sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: parameterSetPointers,
                        parameterSetSizes: parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &formatDescription
                    )
                }
            }

            guard status == noErr, let formatDescription else {
                throw DecoderError.configurationFailed(status)
            }

            try createSession(formatDescription: formatDescription)
            waitingForKeyFrame = true
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func decodeOnQueue(_ frame: ControlVideoFrame) {
        guard let decompressionSession, let formatDescription else {
            onDroppedFrame?()
            return
        }

        if waitingForKeyFrame && !frame.keyFrame && !frame.data.containsIDRFrame {
            onDroppedFrame?()
            return
        }

        guard let avccData = frame.data.annexBToLengthPrefixed() else {
            onDroppedFrame?()
            return
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = avccData.withUnsafeBytes { buffer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avccData.count,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            ) == noErr && CMBlockBufferReplaceDataBytes(
                with: buffer.baseAddress!,
                blockBuffer: blockBuffer!,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            ) == noErr
        }

        guard blockStatus, let blockBuffer else {
            onDroppedFrame?()
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avccData.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame.timestamp), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer else {
            onDroppedFrame?()
            return
        }

        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: flags,
            frameRefcon: nil,
            infoFlagsOut: nil
        )

        if status == noErr {
            waitingForKeyFrame = false
        } else {
            waitingForKeyFrame = true
            onDroppedFrame?()
        }
    }

    private func createSession(formatDescription: CMVideoFormatDescription) throws {
        invalidateOnQueue()

        let callback: VTDecompressionOutputCallback = { refcon, _, status, _, imageBuffer, _, _ in
            guard status == noErr,
                  let imageBuffer,
                  let refcon else {
                return
            }

            let decoder = Unmanaged<ControlH264Decoder>.fromOpaque(refcon).takeUnretainedValue()
            var cgImage: CGImage?
            let imageStatus = VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &cgImage)
            if imageStatus == noErr, let cgImage {
                decoder.onImage?(cgImage)
            }
        }

        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: callback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &record,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw DecoderError.sessionFailed(status)
        }

        decompressionSession = session
    }

    private func invalidateOnQueue() {
        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
    }

    private func parseConfiguration(_ payload: Data) throws -> (sps: Data, pps: Data) {
        guard payload.count >= 10 else {
            throw DecoderError.invalidConfiguration
        }

        var offset = payload.startIndex
        let spsLength = Int(payload.readUInt32BE(at: offset))
        offset += 4
        guard spsLength > 0, offset + spsLength + 4 <= payload.endIndex else {
            throw DecoderError.invalidConfiguration
        }

        let sps = Data(payload[offset..<(offset + spsLength)])
        offset += spsLength

        let ppsLength = Int(payload.readUInt32BE(at: offset))
        offset += 4
        guard ppsLength > 0, offset + ppsLength <= payload.endIndex else {
            throw DecoderError.invalidConfiguration
        }

        let pps = Data(payload[offset..<(offset + ppsLength)])
        return (sps, pps)
    }

    private enum DecoderError: LocalizedError {
        case invalidConfiguration
        case configurationFailed(OSStatus)
        case sessionFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return "The H.264 configuration packet is invalid."
            case .configurationFailed(let status):
                return "The H.264 format could not be created (\(status))."
            case .sessionFailed(let status):
                return "The H.264 decoder could not start (\(status))."
            }
        }
    }
}

private extension Data {
    var containsIDRFrame: Bool {
        var offset = startIndex
        while offset + 4 < endIndex {
            guard self[offset] == 0, self[offset + 1] == 0 else {
                offset += 1
                continue
            }

            let startCodeLength: Int
            if self[offset + 2] == 1 {
                startCodeLength = 3
            } else if offset + 3 < endIndex, self[offset + 2] == 0, self[offset + 3] == 1 {
                startCodeLength = 4
            } else {
                offset += 1
                continue
            }

            let nalIndex = offset + startCodeLength
            if nalIndex < endIndex, self[nalIndex] & 0x1f == 5 {
                return true
            }
            offset = nalIndex + 1
        }
        return false
    }

    func annexBToLengthPrefixed() -> Data? {
        var ranges: [Range<Data.Index>] = []
        var searchIndex = startIndex
        var currentNALStart: Data.Index?

        while searchIndex + 3 < endIndex {
            let startCodeLength: Int?
            if self[searchIndex] == 0,
               self[searchIndex + 1] == 0,
               self[searchIndex + 2] == 1 {
                startCodeLength = 3
            } else if searchIndex + 3 < endIndex,
                      self[searchIndex] == 0,
                      self[searchIndex + 1] == 0,
                      self[searchIndex + 2] == 0,
                      self[searchIndex + 3] == 1 {
                startCodeLength = 4
            } else {
                searchIndex += 1
                continue
            }

            if let currentNALStart {
                ranges.append(currentNALStart..<searchIndex)
            }

            searchIndex += startCodeLength ?? 0
            currentNALStart = searchIndex
        }

        if let currentNALStart, currentNALStart < endIndex {
            ranges.append(currentNALStart..<endIndex)
        }

        guard !ranges.isEmpty else {
            return nil
        }

        var output = Data()
        for range in ranges {
            let length = UInt32(range.count).bigEndian
            var networkLength = length
            Swift.withUnsafeBytes(of: &networkLength) { bytes in
                output.append(contentsOf: bytes)
            }
            output.append(contentsOf: self[range])
        }
        return output
    }
}

final class ControlAudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.zakk.KittenCam.control-audio")
    private var configuration: ControlAudioConfiguration?
    private var outputFormat: AVAudioFormat?
    private var isStarted = false
    private let monitoringGain: Float = 20.0
    private let softLimitThreshold: Float = 0.82

    init() {
        engine.attach(playerNode)
    }

    func configure(_ configuration: ControlAudioConfiguration) {
        queue.async { [weak self] in
            self?.configureOnQueue(configuration)
        }
    }

    func enqueue(_ frame: ControlAudioFrame) {
        queue.async { [weak self] in
            self?.enqueueOnQueue(frame)
        }
    }

    func setVolume(_ volume: Float) {
        playerNode.volume = max(0, min(volume, 1))
    }

    func reset() {
        queue.async { [weak self] in
            self?.playerNode.stop()
            self?.engine.stop()
            self?.isStarted = false
        }
    }

    private func configureOnQueue(_ configuration: ControlAudioConfiguration) {
        guard configuration.bitsPerChannel == 16,
              configuration.sampleRate > 0,
              configuration.channels > 0 else {
            return
        }

        self.configuration = configuration
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: configuration.sampleRate,
            channels: AVAudioChannelCount(configuration.channels),
            interleaved: false
        ) else {
            return
        }

        outputFormat = format
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        do {
            try configureAudioSession()
            engine.mainMixerNode.outputVolume = 1.0

            if !engine.isRunning {
                try engine.start()
            }
            if !playerNode.isPlaying {
                playerNode.play()
            }
            isStarted = true
        } catch {
            isStarted = false
        }
    }

    private func enqueueOnQueue(_ frame: ControlAudioFrame) {
        guard let configuration, let outputFormat else {
            return
        }

        if !isStarted {
            configureOnQueue(configuration)
        }

        let channels = configuration.channels
        let bytesPerFrame = max(channels * 2, 1)
        let availableFrames = frame.data.count / bytesPerFrame
        let frameCount = min(Int(frame.sampleCount), availableFrames)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let floatData = buffer.floatChannelData else {
            return
        }

        frame.data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }

            for frameIndex in 0..<frameCount {
                for channel in 0..<channels {
                    let byteOffset = (frameIndex * channels + channel) * 2
                    let low = UInt16(base[byteOffset])
                    let high = UInt16(base[byteOffset + 1]) << 8
                    let sample = Int16(bitPattern: high | low)
                    let boostedSample = (Float(sample) / 32768.0) * monitoringGain
                    floatData[channel][frameIndex] = softLimit(boostedSample)
                }
            }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try audioSession.setActive(true)
        try audioSession.overrideOutputAudioPort(.speaker)
    }

    private func softLimit(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > softLimitThreshold else {
            return sample
        }

        let remainingHeadroom = 1 - softLimitThreshold
        let compressedPeak = remainingHeadroom * Float(tanh(Double((magnitude - softLimitThreshold) / remainingHeadroom)))
        let limitedMagnitude = softLimitThreshold + compressedPeak
        return sample < 0 ? -limitedMagnitude : limitedMagnitude
    }
}
