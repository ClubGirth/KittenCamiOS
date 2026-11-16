import AVFoundation
import Combine
import Foundation
import Network

private enum TalkBackSenderPacketType: UInt8 {
    case audioConfiguration = 1
    case audioFrame = 2
}

final class TalkBackAudioSender: ObservableObject {
    @Published private(set) var isSending = false
    @Published private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.zakk.KittenCam.talkback-sender")
    private let engine = AVAudioEngine()
    private var connection: NWConnection?
    private var captureFormat: AVAudioFormat?
    private var pendingPackets: [Data] = []
    private var isPacketSendInFlight = false
    private var hasInstalledTap = false

    func start(to endpoint: ControlCameraEndpoint) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            queue.async { [weak self] in
                self?.startOnQueue(to: endpoint)
            }

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else {
                    return
                }

                if granted {
                    self.queue.async {
                        self.startOnQueue(to: endpoint)
                    }
                } else {
                    self.publishError("Microphone permission is required for talkback.")
                    self.publishSending(false)
                }
            }

        default:
            publishError("Microphone permission is required for talkback.")
            publishSending(false)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue(to endpoint: ControlCameraEndpoint) {
        guard connection == nil else {
            return
        }

        guard let nwEndpoint = endpoint.nwEndpoint else {
            publishError(ControlDeviceError.invalidEndpoint.localizedDescription)
            publishSending(false)
            return
        }

        do {
            try configureAudioSession()
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                publishError("The microphone input format is unavailable.")
                publishSending(false)
                return
            }

            captureFormat = format

            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            let connection = NWConnection(to: nwEndpoint, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleConnectionState(state)
            }
            connection.start(queue: queue)
            publishSending(true)
            publishError(nil)
        } catch {
            publishError("Talkback could not start: \(error.localizedDescription)")
            publishSending(false)
        }
    }

    private func stopOnQueue() {
        if hasInstalledTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }

        engine.stop()
        pendingPackets.removeAll()
        isPacketSendInFlight = false
        connection?.cancel()
        connection = nil
        captureFormat = nil
        publishSending(false)
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendConfiguration()
            startCapture()

        case .failed(let error):
            publishError("Talkback connection failed: \(error.localizedDescription)")
            stopOnQueue()

        case .cancelled:
            stopOnQueue()

        default:
            break
        }
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try audioSession.setPreferredSampleRate(48_000)
        try audioSession.setPreferredIOBufferDuration(0.02)
        try audioSession.setActive(true)
    }

    private func startCapture() {
        guard !hasInstalledTap, let captureFormat else {
            return
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: captureFormat) { [weak self] buffer, _ in
            guard let self else {
                return
            }

            self.queue.async {
                self.sendAudioBuffer(buffer)
            }
        }
        hasInstalledTap = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            publishError("Microphone capture could not start: \(error.localizedDescription)")
            stopOnQueue()
        }
    }

    private func sendConfiguration() {
        guard let captureFormat else {
            return
        }

        let configuration = TalkBackAudioConfiguration(
            sampleRate: captureFormat.sampleRate,
            channels: Int(captureFormat.channelCount),
            bitsPerChannel: 16
        )

        guard let payload = try? JSONEncoder().encode(configuration) else {
            return
        }

        enqueue(packet(type: .audioConfiguration, payload: payload))
    }

    private func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let format = captureFormat,
              let floatData = buffer.floatChannelData else {
            return
        }

        let channelCount = Int(format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else {
            return
        }

        var audioData = Data(capacity: frameCount * channelCount * 2)
        for frameIndex in 0..<frameCount {
            for channel in 0..<channelCount {
                let sample = max(-1, min(1, floatData[channel][frameIndex]))
                let scaled = Int16(sample * Float(Int16.max))
                audioData.append(UInt8(truncatingIfNeeded: scaled))
                audioData.append(UInt8(truncatingIfNeeded: scaled >> 8))
            }
        }

        var payload = Data(capacity: 4 + audioData.count)
        payload.appendUInt32BE(UInt32(frameCount))
        payload.append(audioData)
        enqueue(packet(type: .audioFrame, payload: payload))
    }

    private func packet(type: TalkBackSenderPacketType, payload: Data) -> Data {
        var data = Data(capacity: 5 + payload.count)
        data.append(type.rawValue)
        data.appendUInt32BE(UInt32(payload.count))
        data.append(payload)
        return data
    }

    private func enqueue(_ packet: Data) {
        pendingPackets.append(packet)
        flushIfNeeded()
    }

    private func flushIfNeeded() {
        guard !isPacketSendInFlight,
              !pendingPackets.isEmpty,
              let connection else {
            return
        }

        let packet = pendingPackets.removeFirst()
        isPacketSendInFlight = true
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else {
                return
            }

            self.isPacketSendInFlight = false
            if let error {
                self.publishError("Talkback send failed: \(error.localizedDescription)")
                self.stopOnQueue()
                return
            }

            self.flushIfNeeded()
        })
    }

    private func publishSending(_ value: Bool) {
        DispatchQueue.main.async {
            self.isSending = value
        }
    }

    private func publishError(_ message: String?) {
        DispatchQueue.main.async {
            self.lastError = message
        }
    }
}

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
