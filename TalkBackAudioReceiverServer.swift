import AVFoundation
import Combine
import Foundation
import Network
import UIKit

private enum TalkBackPacketType: UInt8 {
    case audioConfiguration = 1
    case audioFrame = 2
}

struct TalkBackAudioConfiguration: Codable, Equatable {
    let sampleRate: Double
    let channels: Int
    let bitsPerChannel: Int
}

struct TalkBackAudioFrame {
    let sampleCount: Int
    let data: Data
}

final class TalkBackAudioReceiverServer: ObservableObject {
    static let shared = TalkBackAudioReceiverServer()

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16?
    @Published private(set) var connectedClientCount = 0
    @Published private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.zakk.KittenCam.talkback-receiver")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: TalkBackReceiverClient] = [:]
    private let player = TalkBackAudioPlayer()

    private init() {}

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue() {
        guard listener == nil else {
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true

            let listener = try NWListener(using: parameters, on: .any)
            listener.service = NWListener.Service(
                name: UIDevice.current.name,
                type: "_kittencam-talk._tcp"
            )

            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            self.listener = listener
            listener.start(queue: queue)
        } catch {
            publishError("Talkback receiver could not start: \(error.localizedDescription)")
        }
    }

    private func stopOnQueue() {
        for client in clients.values {
            client.cancel()
        }
        clients.removeAll()
        listener?.cancel()
        listener = nil
        player.reset()
        publishState(isRunning: false, port: nil)
        publishClientCount()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            publishState(isRunning: true, port: listener?.port?.rawValue)
            publishError(nil)

        case .failed(let error):
            publishError("Talkback receiver failed: \(error.localizedDescription)")
            stopOnQueue()

        case .cancelled:
            publishState(isRunning: false, port: nil)

        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = TalkBackReceiverClient(connection: connection, queue: queue)
        let identifier = ObjectIdentifier(client)

        client.onConfiguration = { [weak self] configuration in
            self?.player.configure(configuration)
        }

        client.onFrame = { [weak self] frame in
            self?.player.enqueue(frame)
        }

        client.onDisconnect = { [weak self] in
            guard let self else {
                return
            }

            self.clients.removeValue(forKey: identifier)
            self.publishClientCount()
        }

        clients[identifier] = client
        publishClientCount()
        client.start()
    }

    private func publishState(isRunning: Bool, port: UInt16?) {
        DispatchQueue.main.async {
            self.isRunning = isRunning
            self.port = port
        }
    }

    private func publishClientCount() {
        let count = clients.count
        DispatchQueue.main.async {
            self.connectedClientCount = count
        }
    }

    private func publishError(_ message: String?) {
        DispatchQueue.main.async {
            self.lastError = message
        }
    }
}

private final class TalkBackReceiverClient {
    var onConfiguration: ((TalkBackAudioConfiguration) -> Void)?
    var onFrame: ((TalkBackAudioFrame) -> Void)?
    var onDisconnect: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var isCancelled = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }
        connection.start(queue: queue)
    }

    func cancel() {
        guard !isCancelled else {
            return
        }
        isCancelled = true
        connection.cancel()
        onDisconnect?()
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            receiveNext()
        case .failed, .cancelled:
            cancel()
        default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }

            if error != nil || isComplete {
                self.cancel()
                return
            }

            self.receiveNext()
        }
    }

    private func processBuffer() {
        while buffer.count >= 5 {
            let type = buffer[buffer.startIndex]
            let payloadLength = Int(buffer.readUInt32BE(at: buffer.startIndex + 1))
            let packetLength = 5 + payloadLength

            guard payloadLength >= 0 else {
                cancel()
                return
            }

            guard buffer.count >= packetLength else {
                return
            }

            let payloadStart = buffer.startIndex + 5
            let payloadEnd = payloadStart + payloadLength
            let payload = Data(buffer[payloadStart..<payloadEnd])
            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
            handle(type: type, payload: payload)
        }
    }

    private func handle(type: UInt8, payload: Data) {
        switch TalkBackPacketType(rawValue: type) {
        case .audioConfiguration:
            if let configuration = try? JSONDecoder().decode(TalkBackAudioConfiguration.self, from: payload) {
                onConfiguration?(configuration)
            }

        case .audioFrame:
            guard payload.count >= 4 else {
                return
            }

            let sampleCount = Int(payload.readUInt32BE(at: payload.startIndex))
            let audioData = Data(payload[(payload.startIndex + 4)..<payload.endIndex])
            onFrame?(TalkBackAudioFrame(sampleCount: sampleCount, data: audioData))

        case nil:
            break
        }
    }
}

private final class TalkBackAudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.zakk.KittenCam.talkback-player")
    private var configuration: TalkBackAudioConfiguration?
    private var outputFormat: AVAudioFormat?
    private var isStarted = false
    private let playbackGain: Float = 20.0
    private let softLimitThreshold: Float = 0.82

    init() {
        engine.attach(playerNode)
    }

    func configure(_ configuration: TalkBackAudioConfiguration) {
        queue.async { [weak self] in
            self?.configureOnQueue(configuration)
        }
    }

    func enqueue(_ frame: TalkBackAudioFrame) {
        queue.async { [weak self] in
            self?.enqueueOnQueue(frame)
        }
    }

    func reset() {
        queue.async { [weak self] in
            self?.playerNode.stop()
            self?.engine.stop()
            self?.isStarted = false
        }
    }

    private func configureOnQueue(_ configuration: TalkBackAudioConfiguration) {
        guard configuration.bitsPerChannel == 16,
              configuration.sampleRate > 0,
              configuration.channels > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: configuration.sampleRate,
                channels: AVAudioChannelCount(configuration.channels),
                interleaved: false
              ) else {
            return
        }

        self.configuration = configuration
        outputFormat = format
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        playerNode.volume = 1.0

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .videoChat,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            try audioSession.setActive(true)
            try audioSession.overrideOutputAudioPort(.speaker)
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

    private func enqueueOnQueue(_ frame: TalkBackAudioFrame) {
        guard let configuration, let outputFormat else {
            return
        }

        if !isStarted {
            configureOnQueue(configuration)
        }

        let channels = configuration.channels
        let bytesPerFrame = max(channels * 2, 1)
        let availableFrames = frame.data.count / bytesPerFrame
        let frameCount = min(frame.sampleCount, availableFrames)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let floatData = buffer.floatChannelData else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
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
                    let boostedSample = (Float(sample) / 32768.0) * playbackGain
                    floatData[channel][frameIndex] = softLimit(boostedSample)
                }
            }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
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

private extension Data {
    func readUInt32BE(at index: Data.Index) -> UInt32 {
        var value: UInt32 = 0
        for offset in 0..<4 {
            value = (value << 8) | UInt32(self[index + offset])
        }
        return value
    }
}
