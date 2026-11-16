import Combine
import Foundation
import Network
import UIKit

struct CameraCommand: Decodable {
    let command: String

    let zoom: Double?
    let rate: Float?

    let enabled: Bool?
    let level: Float?

    let resolution: String?
    let fps: Int?
}

struct CameraStatusResponse: Encodable {
    let success: Bool
    let message: String

    let zoom: Double
    let torchEnabled: Bool
    let torchLevel: Float

    let resolution: String
    let fps: Int

    let microphoneEnabled: Bool
    let microphoneAuthorized: Bool
    let microphoneMode: String
}

final class CameraCommandServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16?
    @Published private(set) var connectedClientCount = 0
    @Published private(set) var lastCommand = "None"
    @Published private(set) var serverError: String?

    private weak var camera: CameraManager?

    private let serverQueue = DispatchQueue(
        label: "com.zakk.KittenCam.command-server"
    )

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(camera: CameraManager) {
        self.camera = camera
    }

    func start() {
        serverQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard self.listener == nil else {
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

                listener.service = NWListener.Service(
                    name: UIDevice.current.name,
                    type: "_kittencam._tcp"
                )

                listener.stateUpdateHandler = {
                    [weak self] state in

                    self?.handleListenerState(state)
                }

                listener.newConnectionHandler = {
                    [weak self] connection in

                    self?.accept(connection)
                }

                self.listener = listener
                listener.start(queue: self.serverQueue)
            } catch {
                self.publishError(
                    "Server could not start: \(error.localizedDescription)"
                )
            }
        }
    }

    func stop() {
        serverQueue.async { [weak self] in
            guard let self else {
                return
            }

            for connection in self.connections.values {
                connection.cancel()
            }

            self.connections.removeAll()

            self.listener?.cancel()
            self.listener = nil

            DispatchQueue.main.async {
                self.isRunning = false
                self.port = nil
                self.connectedClientCount = 0
            }
        }
    }

    private func handleListenerState(
        _ state: NWListener.State
    ) {
        switch state {
        case .ready:
            let listenerPort = listener?.port?.rawValue

            DispatchQueue.main.async {
                self.isRunning = true
                self.port = listenerPort
                self.serverError = nil
            }

        case .waiting(let error):
            publishError(
                "Server is waiting: \(error.localizedDescription)"
            )

        case .failed(let error):
            publishError(
                "Server failed: \(error.localizedDescription)"
            )

            listener?.cancel()
            listener = nil

        case .cancelled:
            DispatchQueue.main.async {
                self.isRunning = false
                self.port = nil
            }

        case .setup:
            break

        @unknown default:
            break
        }
    }

    private func accept(
        _ connection: NWConnection
    ) {
        let identifier = ObjectIdentifier(connection)

        connections[identifier] = connection
        publishConnectionCount()

        connection.stateUpdateHandler = {
            [weak self, weak connection] state in

            guard let self,
                  let connection else {
                return
            }

            switch state {
            case .ready:
                self.receiveRequest(
                    from: connection
                )

            case .failed, .cancelled:
                self.removeConnection(
                    connection
                )

            default:
                break
            }
        }

        connection.start(queue: serverQueue)
    }

    private func receiveRequest(
        from connection: NWConnection
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1_048_576
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data,
               !data.isEmpty {
                self.handleHTTPRequest(
                    data,
                    connection: connection
                )
            } else if let error {
                self.sendHTTPResponse(
                    statusCode: 400,
                    body: self.errorJSON(
                        "Request failed: \(error.localizedDescription)"
                    ),
                    connection: connection
                )
            } else if isComplete {
                self.removeConnection(connection)
            }
        }
    }

    private func handleHTTPRequest(
        _ data: Data,
        connection: NWConnection
    ) {
        guard let requestText = String(
            data: data,
            encoding: .utf8
        ) else {
            sendHTTPResponse(
                statusCode: 400,
                body: errorJSON("Request was not valid UTF-8."),
                connection: connection
            )
            return
        }

        guard let headerEnd =
                requestText.range(
                    of: "\r\n\r\n"
                ) else {
            sendHTTPResponse(
                statusCode: 400,
                body: errorJSON("Incomplete HTTP request."),
                connection: connection
            )
            return
        }

        let headerText = String(
            requestText[..<headerEnd.lowerBound]
        )

        let bodyText = String(
            requestText[headerEnd.upperBound...]
        )

        let requestLine =
            headerText.components(
                separatedBy: "\r\n"
            ).first ?? ""

        let requestParts =
            requestLine.split(separator: " ")

        guard requestParts.count >= 2 else {
            sendHTTPResponse(
                statusCode: 400,
                body: errorJSON("Invalid request line."),
                connection: connection
            )
            return
        }

        let method = String(requestParts[0])
        let path = String(requestParts[1])

        switch (method, path) {
        case ("GET", "/status"):
            sendStatus(
                message: "KittenCam is ready.",
                connection: connection
            )

        case ("POST", "/command"):
            handleCommand(
                bodyText: bodyText,
                connection: connection
            )

        default:
            sendHTTPResponse(
                statusCode: 404,
                body: errorJSON("Endpoint not found."),
                connection: connection
            )
        }
    }

    private func handleCommand(
        bodyText: String,
        connection: NWConnection
    ) {
        guard let bodyData =
                bodyText.data(using: .utf8) else {
            sendHTTPResponse(
                statusCode: 400,
                body: errorJSON("Invalid request body."),
                connection: connection
            )
            return
        }

        do {
            let command = try JSONDecoder().decode(
                CameraCommand.self,
                from: bodyData
            )

            execute(
                command,
                connection: connection
            )
        } catch {
            sendHTTPResponse(
                statusCode: 400,
                body: errorJSON(
                    "Invalid command JSON: \(error.localizedDescription)"
                ),
                connection: connection
            )
        }
    }

    private func execute(
        _ command: CameraCommand,
        connection: NWConnection
    ) {
        guard let camera else {
            sendHTTPResponse(
                statusCode: 500,
                body: errorJSON(
                    "Camera manager is unavailable."
                ),
                connection: connection
            )
            return
        }

        DispatchQueue.main.async {
            self.lastCommand = command.command

            switch command.command {
            case "setZoom":
                guard let zoom = command.zoom else {
                    self.sendMissingArgument(
                        "zoom",
                        connection: connection
                    )
                    return
                }

                camera.setZoom(CGFloat(zoom))

                self.sendStatus(
                    message: "Zoom updated.",
                    connection: connection
                )

            case "smoothZoom":
                guard let zoom = command.zoom else {
                    self.sendMissingArgument(
                        "zoom",
                        connection: connection
                    )
                    return
                }

                camera.smoothZoom(
                    to: CGFloat(zoom),
                    rate: command.rate ?? 2.0
                )

                self.sendStatus(
                    message: "Smooth zoom started.",
                    connection: connection
                )

            case "setTorch":
                guard let enabled =
                        command.enabled else {
                    self.sendMissingArgument(
                        "enabled",
                        connection: connection
                    )
                    return
                }

                camera.setTorch(
                    enabled: enabled,
                    level: command.level
                )

                self.sendStatus(
                    message: "Torch updated.",
                    connection: connection
                )

            case "setMicrophone":
                guard let enabled =
                        command.enabled
                else {
                    self.sendMissingArgument(
                        "enabled",
                        connection: connection
                    )

                    return
                }

                camera.setMicrophoneEnabled(
                    enabled
                )

                self.sendStatus(
                    message:
                        "Microphone updated.",
                    connection: connection
                )

            case "setVideoFormat":
                guard let resolutionText =
                        command.resolution,
                      let fps = command.fps else {
                    self.sendHTTPResponse(
                        statusCode: 400,
                        body: self.errorJSON(
                            "resolution and fps are required."
                        ),
                        connection: connection
                    )
                    return
                }

                guard let resolution =
                        self.parseResolution(
                            resolutionText
                        ) else {
                    self.sendHTTPResponse(
                        statusCode: 400,
                        body: self.errorJSON(
                            "Unknown resolution: \(resolutionText)"
                        ),
                        connection: connection
                    )
                    return
                }

                camera.setVideoFormat(
                    resolution: resolution,
                    fps: fps
                )

                self.sendStatus(
                    message: "Video format change requested.",
                    connection: connection
                )

            default:
                self.sendHTTPResponse(
                    statusCode: 400,
                    body: self.errorJSON(
                        "Unknown command: \(command.command)"
                    ),
                    connection: connection
                )
            }
        }
    }

    private func parseResolution(
        _ text: String
    ) -> VideoResolution? {
        switch text.lowercased() {
        case "720p":
            return .p720

        case "1080p":
            return .p1080

        case "1440p":
            return .p1440

        case "4k", "2160p":
            return .p4K

        default:
            return nil
        }
    }

    private func sendStatus(
        message: String,
        connection: NWConnection
    ) {
        guard let camera else {
            sendHTTPResponse(
                statusCode: 500,
                body: errorJSON(
                    "Camera manager is unavailable."
                ),
                connection: connection
            )
            return
        }

        let response = CameraStatusResponse(
            success: true,
            message: message,
            zoom: Double(camera.zoomLevel),
            torchEnabled: camera.torchEnabled,
            torchLevel: camera.torchLevel,
            resolution: camera.selectedResolution.rawValue,
            fps: camera.selectedFPS,
            microphoneEnabled:
                camera.microphoneEnabled,
            microphoneAuthorized:
                camera.microphoneAuthorized,
            microphoneMode:
                camera.activeMicrophoneModeName
        )

        do {
            let body = try JSONEncoder().encode(response)

            sendHTTPResponse(
                statusCode: 200,
                body: body,
                connection: connection
            )
        } catch {
            sendHTTPResponse(
                statusCode: 500,
                body: errorJSON(
                    "Could not encode status."
                ),
                connection: connection
            )
        }
    }

    private func sendMissingArgument(
        _ name: String,
        connection: NWConnection
    ) {
        sendHTTPResponse(
            statusCode: 400,
            body: errorJSON(
                "Missing required argument: \(name)"
            ),
            connection: connection
        )
    }

    private func sendHTTPResponse(
        statusCode: Int,
        body: Data,
        connection: NWConnection
    ) {
        let statusText: String

        switch statusCode {
        case 200:
            statusText = "OK"

        case 400:
            statusText = "Bad Request"

        case 404:
            statusText = "Not Found"

        default:
            statusText = "Internal Server Error"
        }

        let header = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r

        """

        var response = Data(
            header.utf8
        )

        response.append(body)

        connection.send(
            content: response,
            completion: .contentProcessed {
                [weak self] _ in

                connection.cancel()
                self?.removeConnection(connection)
            }
        )
    }

    private func errorJSON(
        _ message: String
    ) -> Data {
        let object: [String: Any] = [
            "success": false,
            "message": message
        ]

        return (
            try? JSONSerialization.data(
                withJSONObject: object
            )
        ) ?? Data()
    }

    private func removeConnection(
        _ connection: NWConnection
    ) {
        let identifier = ObjectIdentifier(connection)

        connections.removeValue(
            forKey: identifier
        )

        publishConnectionCount()
    }

    private func publishConnectionCount() {
        let count = connections.count

        DispatchQueue.main.async {
            self.connectedClientCount = count
        }
    }

    private func publishError(
        _ message: String
    ) {
        DispatchQueue.main.async {
            self.serverError = message
            self.isRunning = false
        }
    }
}
