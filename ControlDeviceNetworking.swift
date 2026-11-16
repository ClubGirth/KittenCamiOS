import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import Network
import SwiftUI
import VideoToolbox

struct ControlCameraEndpoint: Equatable {
    enum EndpointKind: Equatable {
        case hostPort(host: String, port: Int)
        case bonjour(name: String, type: String, domain: String)
    }

    let kind: EndpointKind

    static func hostPort(host: String, port: Int) -> ControlCameraEndpoint {
        ControlCameraEndpoint(kind: .hostPort(host: host, port: port))
    }

    static func bonjour(name: String, type: String, domain: String) -> ControlCameraEndpoint {
        ControlCameraEndpoint(kind: .bonjour(name: name, type: type, domain: domain))
    }

    var host: String {
        switch kind {
        case .hostPort(let host, _):
            return host
        case .bonjour(let name, _, _):
            return name
        }
    }

    var port: Int {
        switch kind {
        case .hostPort(_, let port):
            return port
        case .bonjour:
            return 0
        }
    }

    var displayAddress: String {
        switch kind {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        case .bonjour(let name, let type, _):
            let label = type
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ".tcp", with: "")
            return "\(name) • \(label)"
        }
    }

    var nwEndpoint: NWEndpoint? {
        switch kind {
        case .hostPort(let host, let port):
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                return nil
            }

            return .hostPort(
                host: NWEndpoint.Host(host),
                port: nwPort
            )

        case .bonjour(let name, let type, let domain):
            return .service(
                name: name,
                type: type,
                domain: domain,
                interface: nil
            )
        }
    }
}

struct ControlCameraDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var commandEndpoint: ControlCameraEndpoint?
    var videoEndpoint: ControlCameraEndpoint?
    var talkBackEndpoint: ControlCameraEndpoint?

    var isConnectable: Bool {
        commandEndpoint != nil
    }

    var videoAvailable: Bool {
        videoEndpoint != nil
    }

    var talkBackAvailable: Bool {
        talkBackEndpoint != nil
    }
}

struct RemoteCameraStatus: Decodable {
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

struct RemoteCameraCommand: Encodable {
    let command: String
    var zoom: Double?
    var rate: Float?
    var enabled: Bool?
    var level: Float?
    var resolution: String?
    var fps: Int?
}

final class ControlDeviceDiscovery: ObservableObject {
    @Published private(set) var devices: [ControlCameraDevice] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var refreshTick = 0

    private let queue = DispatchQueue(label: "com.zakk.KittenCam.control-discovery")
    private var commandBrowser: NWBrowser?
    private var videoBrowser: NWBrowser?
    private var talkBackBrowser: NWBrowser?
    private var servicesByKey: [String: DiscoveredService] = [:]

    func start() {
        queue.async { [weak self] in
            self?.restartOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue(clearDevices: true)
        }
    }

    private func restartOnQueue() {
        stopOnQueue(clearDevices: false)
        servicesByKey.removeAll()
        publishDevices()

        DispatchQueue.main.async {
            self.isSearching = true
            self.errorMessage = nil
            self.refreshTick &+= 1
        }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let commandBrowser = NWBrowser(
            for: .bonjour(type: "_kittencam._tcp", domain: "local"),
            using: parameters
        )

        let videoBrowser = NWBrowser(
            for: .bonjour(type: "_kittencam-video._tcp", domain: "local"),
            using: parameters
        )

        let talkBackBrowser = NWBrowser(
            for: .bonjour(type: "_kittencam-talk._tcp", domain: "local"),
            using: parameters
        )

        configure(browser: commandBrowser, kind: .command)
        configure(browser: videoBrowser, kind: .video)
        configure(browser: talkBackBrowser, kind: .talkBack)

        self.commandBrowser = commandBrowser
        self.videoBrowser = videoBrowser
        self.talkBackBrowser = talkBackBrowser

        commandBrowser.start(queue: queue)
        videoBrowser.start(queue: queue)
        talkBackBrowser.start(queue: queue)
    }

    private func stopOnQueue(clearDevices: Bool) {
        commandBrowser?.cancel()
        videoBrowser?.cancel()
        talkBackBrowser?.cancel()
        commandBrowser = nil
        videoBrowser = nil
        talkBackBrowser = nil

        if clearDevices {
            servicesByKey.removeAll()
        }

        DispatchQueue.main.async {
            self.isSearching = false
            if clearDevices {
                self.devices = []
            }
        }
    }

    private func configure(browser: NWBrowser, kind: ServiceKind) {
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }

            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.isSearching = true
                    self.errorMessage = nil
                }

            case .failed(let error):
                DispatchQueue.main.async {
                    self.errorMessage = "Discovery failed: \(error.localizedDescription)"
                    self.isSearching = false
                }

            case .cancelled:
                break

            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.update(results: results, kind: kind)
        }
    }

    private func update(results: Set<NWBrowser.Result>, kind: ServiceKind) {
        let prefix = kind.rawValue
        servicesByKey = servicesByKey.filter { _, service in
            service.kind != kind
        }

        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint else {
                continue
            }

            let normalizedName = normalizedServiceName(name)
            let endpoint = ControlCameraEndpoint.bonjour(
                name: name,
                type: type,
                domain: domain
            )

            let key = "\(prefix)|\(normalizedName)"
            servicesByKey[key] = DiscoveredService(
                kind: kind,
                name: name,
                normalizedName: normalizedName,
                endpoint: endpoint
            )
        }

        publishDevices()
    }

    private func publishDevices() {
        var devicesByName: [String: ControlCameraDevice] = [:]

        for discovered in servicesByKey.values {
            let id = discovered.normalizedName
            var device = devicesByName[id] ?? ControlCameraDevice(
                id: id,
                name: discovered.name,
                commandEndpoint: nil,
                videoEndpoint: nil,
                talkBackEndpoint: nil
            )

            switch discovered.kind {
            case .command:
                device.commandEndpoint = discovered.endpoint
                device.name = discovered.name

            case .video:
                device.videoEndpoint = discovered.endpoint
                if device.name.isEmpty || device.name == "KittenCam" {
                    device.name = discovered.name
                }

            case .talkBack:
                device.talkBackEndpoint = discovered.endpoint
                if device.name.isEmpty || device.name == "KittenCam" {
                    device.name = discovered.name
                }
            }

            devicesByName[id] = device
        }

        let discoveredDevices = devicesByName.values
            .filter { $0.commandEndpoint != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        DispatchQueue.main.async {
            self.devices = discoveredDevices
        }
    }

    private func normalizedServiceName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
    }
}

private enum ServiceKind: String {
    case command
    case video
    case talkBack
}

private struct DiscoveredService {
    let kind: ServiceKind
    let name: String
    let normalizedName: String
    let endpoint: ControlCameraEndpoint
}

final class RemoteCameraCommandClient {
    private let queue = DispatchQueue(label: "com.zakk.KittenCam.remote-command-client")

    func getStatus(endpoint: ControlCameraEndpoint) async throws -> RemoteCameraStatus {
        try await send(endpoint: endpoint, path: "/status", method: "GET", command: nil)
    }

    func sendCommand(_ command: RemoteCameraCommand, endpoint: ControlCameraEndpoint) async throws -> RemoteCameraStatus {
        try await send(endpoint: endpoint, path: "/command", method: "POST", command: command)
    }

    private func send(
        endpoint: ControlCameraEndpoint,
        path: String,
        method: String,
        command: RemoteCameraCommand?
    ) async throws -> RemoteCameraStatus {
        guard let nwEndpoint = endpoint.nwEndpoint else {
            throw ControlDeviceError.invalidEndpoint
        }

        let body = try command.map { try JSONEncoder().encode($0) } ?? Data()
        let request = makeHTTPRequest(
            endpoint: endpoint,
            path: path,
            method: method,
            body: body
        )

        let response = try await sendRawRequest(request, to: nwEndpoint)
        let responseBody = try parseHTTPResponse(response)
        return try JSONDecoder().decode(RemoteCameraStatus.self, from: responseBody)
    }

    private func makeHTTPRequest(
        endpoint: ControlCameraEndpoint,
        path: String,
        method: String,
        body: Data
    ) -> Data {
        let header = """
        \(method) \(path) HTTP/1.1\r
        Host: \(endpoint.host)\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """

        var request = Data(header.utf8)
        request.append(body)
        return request
    }

    private func sendRawRequest(_ request: Data, to endpoint: NWEndpoint) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            let connection = NWConnection(to: endpoint, using: parameters)
            var response = Data()
            var didResume = false
            var timeout: DispatchSourceTimer?

            func finish(_ result: Result<Data, Error>) {
                guard !didResume else {
                    return
                }

                didResume = true
                timeout?.cancel()
                connection.cancel()
                continuation.resume(with: result)
            }

            func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        response.append(data)
                    }

                    if let error {
                        finish(.failure(error))
                        return
                    }

                    if isComplete {
                        finish(.success(response))
                        return
                    }

                    receiveNext()
                }
            }

            timeout = DispatchSource.makeTimerSource(queue: queue)
            timeout?.schedule(deadline: .now() + 5)
            timeout?.setEventHandler {
                finish(.failure(ControlDeviceError.requestTimedOut))
            }
            timeout?.resume()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(error))
                            return
                        }

                        receiveNext()
                    })

                case .failed(let error):
                    finish(.failure(error))

                case .cancelled:
                    break

                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    private func parseHTTPResponse(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8),
              let separatorRange = text.range(of: "\r\n\r\n") else {
            throw ControlDeviceError.invalidResponse
        }

        let headerText = String(text[..<separatorRange.lowerBound])
        let bodyText = String(text[separatorRange.upperBound...])
        let statusLine = headerText.components(separatedBy: "\r\n").first ?? ""
        let statusParts = statusLine.split(separator: " ")
        let statusCode = statusParts.count >= 2 ? Int(statusParts[1]) ?? 0 : 0
        let body = Data(bodyText.utf8)

        if !(200..<300).contains(statusCode) {
            if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let message = object["message"] as? String {
                throw ControlDeviceError.remote(message)
            }

            throw ControlDeviceError.remote("The camera returned HTTP \(statusCode).")
        }

        return body
    }
}

enum ControlDeviceError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case remote(String)
    case missingCommandEndpoint
    case missingVideoEndpoint
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The camera endpoint is invalid."
        case .invalidResponse:
            return "The camera returned an invalid response."
        case .remote(let message):
            return message
        case .missingCommandEndpoint:
            return "The camera command service is not available."
        case .missingVideoEndpoint:
            return "The camera video service is not available yet."
        case .requestTimedOut:
            return "The camera connection timed out."
        }
    }
}
