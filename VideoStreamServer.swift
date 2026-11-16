import Foundation
import Network
import Combine
import UIKit

private struct KittenCamOrientationMetadata:
    Equatable {

    let name: String
    let rotationDegreesClockwise: Int
    let isPortrait: Bool

    var rotationDegreesCounterClockwise: Int {
        (
            360 -
            rotationDegreesClockwise
        ) % 360
    }

    static let portrait =
        KittenCamOrientationMetadata(
            name: "portrait",
            rotationDegreesClockwise: 90,
            isPortrait: true
        )

    static let portraitUpsideDown =
        KittenCamOrientationMetadata(
            name: "portraitUpsideDown",
            rotationDegreesClockwise: 270,
            isPortrait: true
        )

    static let landscapeLeft =
        KittenCamOrientationMetadata(
            name: "landscapeLeft",
            rotationDegreesClockwise: 180,
            isPortrait: false
        )

    static let landscapeRight =
        KittenCamOrientationMetadata(
            name: "landscapeRight",
            rotationDegreesClockwise: 0,
            isPortrait: false
        )
}

final class VideoStreamServer: ObservableObject {
    static let shared = VideoStreamServer()

    @Published private(set) var isRunning = false
    @Published private(set) var connectedClientCount = 0
    @Published private(set) var port: UInt16?
    @Published private(set) var lastError: String?

    private let serverQueue = DispatchQueue(
        label: "com.kittencam.video-stream-server"
    )

    private var listener: NWListener?
    private var clients: [UUID: StreamClient] = [:]
    private var heartbeatTimer: DispatchSourceTimer?

    private var orientationObserver:
        NSObjectProtocol?

    private var applicationActiveObserver:
        NSObjectProtocol?

    private var currentOrientation =
        KittenCamOrientationMetadata.portrait

    private var orientationRevision:
        UInt64 = 0

    private var encodedWidth = 0
    private var encodedHeight = 0
    private var encodedFrameRate = 0

    private var audioEnabled = false
    private var audioSampleRate = 0.0
    private var audioChannelCount = 0
    private var audioBitsPerChannel = 0

    private var latestAudioConfigurationPacket:
        Data?

    private init() {}

    func start() {
        serverQueue.async { [weak self] in
            self?.startOnServerQueue()
        }
    }

    func stop() {
        serverQueue.async { [weak self] in
            self?.stopOnServerQueue()
        }
    }

    func broadcast(
        type: KittenCamPacketType,
        payload: Data
    ) {
        let packet = KittenCamPacket(
            type: type,
            payload: payload
        ).encoded()

        serverQueue.async { [weak self] in
            guard let self else {
                return
            }

            if type ==
                .audioConfiguration {
                latestAudioConfigurationPacket =
                    packet
            }

            for client in clients.values {
                client.send(packet)
            }
        }
    }

    func broadcastEncodedPacket(_ packet: Data) {
        serverQueue.async { [weak self] in
            guard let self else {
                return
            }

            for client in clients.values {
                client.send(packet)
            }
        }
    }

    func updateVideoFormat(
        width: Int,
        height: Int,
        fps: Int
    ) {
        serverQueue.async { [weak self] in
            guard let self else {
                return
            }

            let normalizedWidth =
                max(width, 0)

            let normalizedHeight =
                max(height, 0)

            let normalizedFPS =
                max(fps, 0)

            guard
                normalizedWidth !=
                    encodedWidth ||
                normalizedHeight !=
                    encodedHeight ||
                normalizedFPS !=
                    encodedFrameRate
            else {
                return
            }

            encodedWidth =
                normalizedWidth

            encodedHeight =
                normalizedHeight

            encodedFrameRate =
                normalizedFPS

            broadcastStreamInformation()
        }
    }


    func updateAudioState(
        enabled: Bool
    ) {
        serverQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard
                self.audioEnabled !=
                    enabled
            else {
                return
            }

            self.audioEnabled =
                enabled

            self.broadcastStreamInformation()
        }
    }

    func updateAudioFormat(
        sampleRate: Double,
        channels: Int,
        bitsPerChannel: Int
    ) {
        serverQueue.async { [weak self] in
            guard let self else {
                return
            }

            let normalizedRate =
                max(
                    sampleRate,
                    0
                )

            let normalizedChannels =
                max(
                    channels,
                    0
                )

            let normalizedBits =
                max(
                    bitsPerChannel,
                    0
                )

            guard
                normalizedRate !=
                    self.audioSampleRate ||
                normalizedChannels !=
                    self.audioChannelCount ||
                normalizedBits !=
                    self.audioBitsPerChannel
            else {
                return
            }

            self.audioSampleRate =
                normalizedRate

            self.audioChannelCount =
                normalizedChannels

            self.audioBitsPerChannel =
                normalizedBits

            self.broadcastStreamInformation()
        }
    }

    func updateAudioConfiguration(
        _ payload: Data
    ) {
        broadcast(
            type:
                .audioConfiguration,
            payload: payload
        )
    }

    private func startOnServerQueue() {
        guard listener == nil else {
            return
        }

        do {
            let parameters = NWParameters.tcp

            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true

            let listener = try NWListener(
                using: parameters,
                on: .any
            )

            self.listener = listener

            listener.service = NWListener.Service(
                name: UIDevice.current.name,
                type: "_kittencam-video._tcp"
            )

            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.start(queue: serverQueue)

            startHeartbeat()
            startOrientationMonitoring()
        } catch {
            publishError(
                "Unable to start video stream server: \(error.localizedDescription)"
            )
        }
    }

    private func stopOnServerQueue() {
        stopHeartbeat()
        stopOrientationMonitoring()

        for client in clients.values {
            client.cancel()
        }

        clients.removeAll()

        listener?.cancel()
        listener = nil

        publishState(
            isRunning: false,
            port: nil
        )

        publishClientCount()
    }

    private func handleListenerState(
        _ state: NWListener.State
    ) {
        switch state {
        case .ready:
            let activePort = listener?.port?.rawValue

            publishState(
                isRunning: true,
                port: activePort
            )

            publishError(nil)

            print(
                "KittenCam video server ready on port \(activePort ?? 0)"
            )

        case .failed(let error):
            publishError(
                "Video server failed: \(error.localizedDescription)"
            )

            stopOnServerQueue()

        case .cancelled:
            publishState(
                isRunning: false,
                port: nil
            )

        default:
            break
        }
    }

    private func accept(
        _ connection: NWConnection
    ) {
        let id = UUID()

        let client = StreamClient(
            id: id,
            connection: connection,
            queue: serverQueue
        )

        client.onReady = { [weak self, weak client] in
            guard
                let self,
                let client
            else {
                return
            }

            self.sendInitialInformation(to: client)
        }

        client.onDisconnected = { [weak self] clientID in
            guard let self else {
                return
            }

            self.clients.removeValue(
                forKey: clientID
            )

            self.publishClientCount()
        }

        clients[id] = client
        publishClientCount()

        client.start()
    }

    private func sendInitialInformation(
        to client: StreamClient
    ) {
        guard let packet =
                makeStreamInformationPacket()
        else {
            return
        }

        client.send(packet)

        if audioEnabled,
           let latestAudioConfigurationPacket {
            client.send(
                latestAudioConfigurationPacket
            )
        }
    }

    private func broadcastStreamInformation() {
        guard let packet =
                makeStreamInformationPacket()
        else {
            return
        }

        for client in clients.values {
            client.send(packet)
        }
    }

    private func makeStreamInformationPacket()
        -> Data? {
        let orientation =
            currentOrientation

        let displayWidth: Int
        let displayHeight: Int

        if orientation.isPortrait {
            displayWidth =
                encodedHeight

            displayHeight =
                encodedWidth
        } else {
            displayWidth =
                encodedWidth

            displayHeight =
                encodedHeight
        }

        var information:
            [String: Any] = [
                "protocolVersion":
                    KittenCamPacket.protocolVersion,

                "deviceName":
                    UIDevice.current.name,

                "streamType":
                    "h264",

                "transport":
                    "tcp",

                /*
                 The encoded H.264 stream remains in its
                 landscape-right capture basis. The desktop
                 should rotate clockwise by this value.
                */
                "encodedOrientation":
                    "landscapeRight",

                "orientation":
                    orientation.name,

                "deviceOrientation":
                    orientation.name,

                "videoOrientation":
                    orientation.name,

                "rotationDegrees":
                    orientation
                        .rotationDegreesClockwise,

                "rotationDegreesClockwise":
                    orientation
                        .rotationDegreesClockwise,

                "rotationDegreesCounterClockwise":
                    orientation
                        .rotationDegreesCounterClockwise,

                "displayRotationDegrees":
                    orientation
                        .rotationDegreesClockwise,

                "isPortrait":
                    orientation.isPortrait,

                "requiresDimensionSwap":
                    orientation.isPortrait,

                "mirrorHorizontally":
                    false,

                "cameraPosition":
                    "back",

                "orientationRevision":
                    orientationRevision,

                "orientationTimestampMilliseconds":
                    UInt64(
                        Date()
                            .timeIntervalSince1970 *
                        1000
                    ),

                "audioEnabled":
                    audioEnabled,

                "audioCodec":
                    "pcm_s16le",

                "audioProfile":
                    "wideCapture"
            ]

        if encodedWidth > 0,
           encodedHeight > 0 {
            information["encodedWidth"] =
                encodedWidth

            information["encodedHeight"] =
                encodedHeight

            information["displayWidth"] =
                displayWidth

            information["displayHeight"] =
                displayHeight
        }

        if encodedFrameRate > 0 {
            information["fps"] =
                encodedFrameRate
        }

        if audioSampleRate > 0 {
            information["audioSampleRate"] =
                audioSampleRate
        }

        if audioChannelCount > 0 {
            information["audioChannels"] =
                audioChannelCount
        }

        if audioBitsPerChannel > 0 {
            information["audioBitsPerChannel"] =
                audioBitsPerChannel
        }

        guard JSONSerialization
            .isValidJSONObject(
                information
            )
        else {
            return nil
        }

        do {
            let payload =
                try JSONSerialization.data(
                    withJSONObject:
                        information
                )

            return KittenCamPacket(
                type: .streamInformation,
                payload: payload
            ).encoded()
        } catch {
            print(
                "Could not create stream information packet: \(error)"
            )

            return nil
        }
    }

    private func startOrientationMonitoring() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            guard
                orientationObserver == nil
            else {
                refreshOrientationFromSystem()
                return
            }

            UIDevice.current
                .beginGeneratingDeviceOrientationNotifications()

            orientationObserver =
                NotificationCenter.default
                    .addObserver(
                        forName:
                            UIDevice
                                .orientationDidChangeNotification,
                        object: nil,
                        queue: .main
                    ) { [weak self] _ in
                        self?
                            .refreshOrientationFromSystem()
                    }

            applicationActiveObserver =
                NotificationCenter.default
                    .addObserver(
                        forName:
                            UIApplication
                                .didBecomeActiveNotification,
                        object: nil,
                        queue: .main
                    ) { [weak self] _ in
                        self?
                            .refreshOrientationFromSystem()
                    }

            refreshOrientationFromSystem()
        }
    }

    private func stopOrientationMonitoring() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            if let orientationObserver {
                NotificationCenter.default
                    .removeObserver(
                        orientationObserver
                    )

                self.orientationObserver =
                    nil
            }

            if let applicationActiveObserver {
                NotificationCenter.default
                    .removeObserver(
                        applicationActiveObserver
                    )

                self.applicationActiveObserver =
                    nil
            }

            UIDevice.current
                .endGeneratingDeviceOrientationNotifications()
        }
    }

    private func refreshOrientationFromSystem() {
        let orientation =
            resolvedOrientation()

        serverQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard
                orientation !=
                    currentOrientation
            else {
                return
            }

            currentOrientation =
                orientation

            orientationRevision &+= 1

            print(
                "KittenCam orientation changed to \(orientation.name), rotate \(orientation.rotationDegreesClockwise)° clockwise."
            )

            broadcastStreamInformation()
        }
    }

    private func resolvedOrientation()
        -> KittenCamOrientationMetadata {
        switch UIDevice.current.orientation {
        case .portrait:
            return .portrait

        case .portraitUpsideDown:
            return .portraitUpsideDown

        case .landscapeLeft:
            return .landscapeLeft

        case .landscapeRight:
            return .landscapeRight

        default:
            break
        }

        let interfaceOrientation =
            UIApplication.shared
                .connectedScenes
                .compactMap {
                    $0 as? UIWindowScene
                }
                .filter {
                    $0.activationState ==
                        .foregroundActive
                }
                .first?
                .interfaceOrientation

        switch interfaceOrientation {
        case .portrait:
            return .portrait

        case .portraitUpsideDown:
            return .portraitUpsideDown

        case .landscapeLeft:
            return .landscapeLeft

        case .landscapeRight:
            return .landscapeRight

        default:
            return currentOrientation
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()

        let timer = DispatchSource.makeTimerSource(
            queue: serverQueue
        )

        timer.schedule(
            deadline: .now() + 2,
            repeating: 2
        )

        timer.setEventHandler { [weak self] in
            let timestamp = UInt64(
                Date().timeIntervalSince1970 * 1000
            )

            var networkTimestamp = timestamp.bigEndian

            let payload = withUnsafeBytes(
                of: &networkTimestamp
            ) {
                Data($0)
            }

            self?.broadcast(
                type: .heartbeat,
                payload: payload
            )
        }

        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func publishState(
        isRunning: Bool,
        port: UInt16?
    ) {
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

    private func publishError(
        _ message: String?
    ) {
        DispatchQueue.main.async {
            self.lastError = message
        }
    }
}

private final class StreamClient {
    let id: UUID

    var onReady: (() -> Void)?
    var onDisconnected: ((UUID) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue

    private var isReady = false
    private var isCancelled = false
    private var isSending = false
    private var didNotifyDisconnect = false

    private var pendingPackets: [Data] = []

    init(
        id: UUID,
        connection: NWConnection,
        queue: DispatchQueue
    ) {
        self.id = id
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }

        connection.start(queue: queue)
    }

    func send(_ packet: Data) {
        guard !isCancelled else {
            return
        }

        pendingPackets.append(packet)
        sendNextPacketIfNeeded()
    }

    func cancel() {
        guard !isCancelled else {
            return
        }

        isCancelled = true
        isReady = false
        pendingPackets.removeAll()

        connection.cancel()
        notifyDisconnectedIfNeeded()
    }

    private func handleState(
        _ state: NWConnection.State
    ) {
        switch state {
        case .ready:
            isReady = true
            onReady?()
            sendNextPacketIfNeeded()

        case .failed(let error):
            print(
                "Stream client failed: \(error.localizedDescription)"
            )

            disconnect()

        case .cancelled:
            disconnect()

        default:
            break
        }
    }

    private func sendNextPacketIfNeeded() {
        guard
            isReady,
            !isSending,
            !pendingPackets.isEmpty,
            !isCancelled
        else {
            return
        }

        isSending = true

        let packet = pendingPackets.removeFirst()

        connection.send(
            content: packet,
            completion: .contentProcessed { [weak self] error in
                guard let self else {
                    return
                }

                self.isSending = false

                if let error {
                    print(
                        "Stream send failed: \(error.localizedDescription)"
                    )

                    self.disconnect()
                    return
                }

                self.sendNextPacketIfNeeded()
            }
        )
    }

    private func disconnect() {
        guard !isCancelled else {
            notifyDisconnectedIfNeeded()
            return
        }

        isCancelled = true
        isReady = false
        pendingPackets.removeAll()

        connection.cancel()
        notifyDisconnectedIfNeeded()
    }

    private func notifyDisconnectedIfNeeded() {
        guard !didNotifyDisconnect else {
            return
        }

        didNotifyDisconnect = true
        onDisconnected?(id)
    }
}
