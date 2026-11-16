import AVFoundation
import Combine
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

@MainActor
final class ControlFeedSession: ObservableObject, Identifiable {
    let id: String
    let name: String
    let device: ControlCameraDevice
    let streamClient = ControlStreamClient()
    let talkBackSender = TalkBackAudioSender()

    @Published var status: RemoteCameraStatus?
    @Published var isMonitoringAudio = true
    @Published var isTalkBackEnabled = false
    @Published var isRecording = false
    @Published var motionRecordingEnabled = false
    @Published var motionSensitivity = MotionSensitivity.medium
    @Published var motionMinimumDuration = 8.0
    @Published var motionLevel = 0.0
    @Published var hoverZoomScale = 1.0
    @Published var panOffset = CGSize.zero
    @Published var lastRecordingURL: URL?

    var recordingStartedAt: Date?
    var motionLastDetectedAt: Date?
    var recordingReason: RecordingReason?
    var previousMotionSample: MotionSample?
    var imageCancellable: AnyCancellable?
    var recorder: ControlFeedRecorder?
    private var talkBackCancellables: Set<AnyCancellable> = []

    init(device: ControlCameraDevice) {
        self.id = device.id
        self.name = device.name
        self.device = device

        talkBackSender.$isSending
            .receive(on: RunLoop.main)
            .sink { [weak self] isSending in
                self?.isTalkBackEnabled = isSending
            }
            .store(in: &talkBackCancellables)
    }

    var commandEndpoint: ControlCameraEndpoint? {
        device.commandEndpoint
    }

    var videoEndpoint: ControlCameraEndpoint? {
        device.videoEndpoint
    }

    var talkBackEndpoint: ControlCameraEndpoint? {
        device.talkBackEndpoint
    }

    var formatText: String {
        if let status {
            return "\(status.resolution) • \(status.fps) FPS"
        }

        if let information = streamClient.streamInformation,
           let width = information.displayWidth ?? information.encodedWidth,
           let height = information.displayHeight ?? information.encodedHeight {
            if let fps = information.fps {
                return "\(width)×\(height) • \(fps) FPS"
            }

            return "\(width)×\(height)"
        }

        return streamClient.stateText
    }
}

enum RecordingReason: String {
    case manual
    case motion
}

enum MotionSensitivity: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case veryHigh = "Very High"

    var id: String { rawValue }

    var threshold: Double {
        switch self {
        case .low:
            return 0.28
        case .medium:
            return 0.18
        case .high:
            return 0.11
        case .veryHigh:
            return 0.065
        }
    }
}

@MainActor
final class ControlDeviceViewModel: ObservableObject {
    @Published var connectedFeeds: [ControlFeedSession] = []
    @Published var selectedFeedID: String?
    @Published var isGridMode = false
    @Published var message: String?

    @Published var zoomDraft = 1.0
    @Published var torchLevelDraft = 0.5
    @Published var selectedResolution = "1080p"
    @Published var selectedFPS = 30

    let discovery = ControlDeviceDiscovery()

    private let commandClient = RemoteCameraCommandClient()
    private var zoomTask: Task<Void, Never>?
    private var torchTask: Task<Void, Never>?
    private var motionTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        discovery.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var selectedFeed: ControlFeedSession? {
        guard let selectedFeedID else {
            return nil
        }

        return connectedFeeds.first { $0.id == selectedFeedID }
    }

    func start() {
        discovery.start()
        startMotionLoop()
    }

    func stop() {
        motionTask?.cancel()
        motionTask = nil
        discovery.stop()
        for feed in connectedFeeds {
            feed.talkBackSender.stop()
            feed.isTalkBackEnabled = false
            feed.streamClient.disconnect()
            stopRecording(feed: feed)
        }
        connectedFeeds.removeAll()
        selectedFeedID = nil
    }

    func refreshDiscovery() {
        discovery.start()
    }

    func connect(_ device: ControlCameraDevice) {
        Task {
            await connectDevice(device)
        }
    }

    func disconnect(_ feed: ControlFeedSession) {
        stopRecording(feed: feed)
        feed.talkBackSender.stop()
        feed.isTalkBackEnabled = false
        feed.streamClient.disconnect()
        feed.imageCancellable?.cancel()
        connectedFeeds.removeAll { $0.id == feed.id }
        if selectedFeedID == feed.id {
            selectedFeedID = connectedFeeds.first?.id
        }
    }

    func disconnect(deviceID: String) {
        guard let feed = connectedFeeds.first(where: { $0.id == deviceID }) else {
            return
        }

        disconnect(feed)
    }

    func selectFeed(_ feed: ControlFeedSession) {
        selectedFeedID = feed.id
        applyStatusDrafts(feed.status)
        applyMonitoringState(feed)
    }

    func setMonitoring(enabled: Bool) {
        guard let feed = selectedFeed else {
            return
        }

        feed.isMonitoringAudio = enabled
        applyMonitoringState(feed)
    }

    func applyZoomPreset(_ zoom: Double) {
        zoomDraft = zoom
        guard let feed = selectedFeed else {
            return
        }

        suppressMotion(for: feed)
        sendCommand(
            RemoteCameraCommand(command: "smoothZoom", zoom: zoom, rate: 2.0),
            feed: feed,
            refreshDelay: 0.18
        )
    }

    func queueZoom(_ zoom: Double) {
        zoomDraft = zoom
        guard let feed = selectedFeed else {
            return
        }

        suppressMotion(for: feed)
        zoomTask?.cancel()
        zoomTask = Task { [weak self, weak feed] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled,
                  let self,
                  let feed else {
                return
            }

            await self.sendCommand(
                RemoteCameraCommand(command: "setZoom", zoom: zoom),
                feed: feed,
                refreshDelay: 0.16
            )
        }
    }

    func setTorch(enabled: Bool) {
        guard let feed = selectedFeed else {
            return
        }

        suppressMotion(for: feed)
        sendCommand(
            RemoteCameraCommand(command: "setTorch", enabled: enabled, level: Float(torchLevelDraft)),
            feed: feed,
            refreshDelay: 0.17
        )
    }

    func queueTorchLevel(_ value: Double) {
        torchLevelDraft = value
        guard let feed = selectedFeed, feed.status?.torchEnabled == true else {
            return
        }

        suppressMotion(for: feed)
        torchTask?.cancel()
        torchTask = Task { [weak self, weak feed] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled,
                  let self,
                  let feed else {
                return
            }

            await self.sendCommand(
                RemoteCameraCommand(command: "setTorch", enabled: true, level: Float(value)),
                feed: feed,
                refreshDelay: 0.16
            )
        }
    }

    func setRemoteMicrophone(enabled: Bool) {
        guard let feed = selectedFeed else {
            return
        }

        sendCommand(
            RemoteCameraCommand(command: "setMicrophone", enabled: enabled),
            feed: feed,
            refreshDelay: 0.2
        )
    }

    func setTalkBack(enabled: Bool) {
        guard let feed = selectedFeed else {
            return
        }

        if enabled {
            guard let endpoint = feed.talkBackEndpoint else {
                message = "Talkback is not available from this camera yet."
                feed.isTalkBackEnabled = false
                return
            }

            feed.isTalkBackEnabled = true
            feed.streamClient.setMonitoringEnabled(false)
            feed.talkBackSender.start(to: endpoint)
        } else {
            feed.talkBackSender.stop()
            feed.isTalkBackEnabled = false
            applyMonitoringState(feed)
        }
    }

    func sendVideoFormat() {
        guard let feed = selectedFeed else {
            return
        }

        sendCommand(
            RemoteCameraCommand(
                command: "setVideoFormat",
                resolution: selectedResolution,
                fps: selectedFPS
            ),
            feed: feed,
            refreshDelay: 0.7
        )
    }

    func toggleRecording(for feed: ControlFeedSession) {
        if feed.isRecording, feed.recordingReason == .manual {
            stopRecording(feed: feed)
        } else {
            startRecording(feed: feed, reason: .manual)
        }
    }

    func toggleGlobalRecording() {
        guard let feed = selectedFeed else {
            message = "Select a feed to record."
            return
        }

        toggleRecording(for: feed)
    }

    func setMotionRecording(_ enabled: Bool) {
        guard let feed = selectedFeed else {
            return
        }

        feed.motionRecordingEnabled = enabled
        if !enabled, feed.recordingReason == .motion {
            stopRecording(feed: feed)
        }
    }

    func updateMotionSensitivity(_ sensitivity: MotionSensitivity) {
        selectedFeed?.motionSensitivity = sensitivity
    }

    func updateMotionMinimumDuration(_ duration: Double) {
        selectedFeed?.motionMinimumDuration = min(max(duration, 1), 600)
    }

    private func connectDevice(_ device: ControlCameraDevice) async {
        guard let commandEndpoint = device.commandEndpoint else {
            message = ControlDeviceError.missingCommandEndpoint.localizedDescription
            return
        }

        do {
            var status = try await commandClient.getStatus(endpoint: commandEndpoint)
            let feed = connectedFeeds.first { $0.id == device.id } ?? ControlFeedSession(device: device)
            feed.status = status

            if !connectedFeeds.contains(where: { $0.id == feed.id }) {
                connectedFeeds.append(feed)
                bindRecording(to: feed)
            }

            selectedFeedID = feed.id
            applyStatusDrafts(status)

            if status.microphoneAuthorized && !status.microphoneEnabled {
                _ = try? await commandClient.sendCommand(
                    RemoteCameraCommand(command: "setMicrophone", enabled: true),
                    endpoint: commandEndpoint
                )
                status = (try? await commandClient.getStatus(endpoint: commandEndpoint)) ?? status
                feed.status = status
            }

            guard let videoEndpoint = device.videoEndpoint else {
                message = "Controls connected. Waiting for video service..."
                return
            }

            feed.streamClient.connect(to: videoEndpoint)
            applyMonitoringState(feed)
        } catch {
            message = error.localizedDescription
        }
    }

    private func sendCommand(
        _ command: RemoteCameraCommand,
        feed: ControlFeedSession,
        refreshDelay: TimeInterval
    ) {
        Task {
            await sendCommand(command, feed: feed, refreshDelay: refreshDelay)
        }
    }

    private func sendCommand(
        _ command: RemoteCameraCommand,
        feed: ControlFeedSession,
        refreshDelay: TimeInterval
    ) async {
        guard let endpoint = feed.commandEndpoint else {
            message = ControlDeviceError.missingCommandEndpoint.localizedDescription
            return
        }

        do {
            let status = try await commandClient.sendCommand(command, endpoint: endpoint)
            feed.status = status
            applyStatusDrafts(status)

            if refreshDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(refreshDelay * 1_000_000_000))
                let refreshed = try await commandClient.getStatus(endpoint: endpoint)
                feed.status = refreshed
                applyStatusDrafts(refreshed)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func applyStatusDrafts(_ status: RemoteCameraStatus?) {
        guard let status else {
            return
        }

        zoomDraft = status.zoom
        torchLevelDraft = Double(status.torchLevel)
        selectedResolution = status.resolution
        selectedFPS = status.fps
    }

    private func applyMonitoringState(_ feed: ControlFeedSession) {
        feed.streamClient.setMonitoringEnabled(feed.isMonitoringAudio && !feed.isTalkBackEnabled)
    }

    private func bindRecording(to feed: ControlFeedSession) {
        feed.imageCancellable = feed.streamClient.$latestImage
            .sink { [weak self, weak feed] image in
                guard let self,
                      let feed,
                      let image else {
                    return
                }

                Task { @MainActor in
                    self.handleNewImage(image, feed: feed)
                }
            }
    }

    private func handleNewImage(_ image: CGImage, feed: ControlFeedSession) {
        feed.recorder?.append(image)
        analyzeMotion(image, feed: feed)
    }

    private func startRecording(feed: ControlFeedSession, reason: RecordingReason) {
        guard !feed.isRecording else {
            return
        }

        guard let image = feed.streamClient.latestImage else {
            message = "The selected feed is not ready to record yet."
            return
        }

        do {
            let recorder = try ControlFeedRecorder(feedName: feed.name, size: CGSize(width: image.width, height: image.height))
            feed.recorder = recorder
            feed.isRecording = true
            feed.recordingReason = reason
            feed.recordingStartedAt = Date()
            recorder.append(image)
        } catch {
            message = error.localizedDescription
        }
    }

    private func stopRecording(feed: ControlFeedSession) {
        guard feed.isRecording else {
            return
        }

        let recorder = feed.recorder
        feed.recorder = nil
        feed.isRecording = false
        feed.recordingReason = nil
        feed.recordingStartedAt = nil

        Task {
            let url = await recorder?.finish()
            await MainActor.run {
                feed.lastRecordingURL = url
                if let url {
                    self.message = "Recording saved: \(url.lastPathComponent)"
                }
            }
        }
    }

    private func startMotionLoop() {
        motionTask?.cancel()
        motionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.tickMotionRecordings()
            }
        }
    }

    private func tickMotionRecordings() {
        let now = Date()
        for feed in connectedFeeds {
            guard feed.recordingReason == .motion,
                  let lastDetected = feed.motionLastDetectedAt else {
                continue
            }

            if now.timeIntervalSince(lastDetected) >= feed.motionMinimumDuration {
                stopRecording(feed: feed)
            }
        }
    }

    private func analyzeMotion(_ image: CGImage, feed: ControlFeedSession) {
        guard feed.motionRecordingEnabled else {
            feed.motionLevel = 0
            feed.previousMotionSample = nil
            return
        }

        guard let sample = MotionSample(image: image) else {
            return
        }

        defer {
            feed.previousMotionSample = sample
        }

        guard let previous = feed.previousMotionSample else {
            return
        }

        let score = sample.difference(from: previous)
        feed.motionLevel = score

        if score >= feed.motionSensitivity.threshold {
            feed.motionLastDetectedAt = Date()
            if !feed.isRecording {
                startRecording(feed: feed, reason: .motion)
            }
        }
    }

    private func suppressMotion(for feed: ControlFeedSession) {
        feed.previousMotionSample = nil
        feed.motionLevel = 0
    }
}

struct MotionSample {
    private let samples: [UInt8]

    init?(image: CGImage) {
        let width = 32
        let height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luminance = [UInt8]()
        luminance.reserveCapacity(width * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index])
            let g = Double(pixels[index + 1])
            let b = Double(pixels[index + 2])
            luminance.append(UInt8(min(max((r * 0.299) + (g * 0.587) + (b * 0.114), 0), 255)))
        }

        samples = luminance
    }

    func difference(from previous: MotionSample) -> Double {
        guard samples.count == previous.samples.count, !samples.isEmpty else {
            return 0
        }

        var total = 0.0
        for index in samples.indices {
            total += Double(abs(Int(samples[index]) - Int(previous.samples[index]))) / 255.0
        }

        return total / Double(samples.count)
    }
}

final class ControlFeedRecorder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let startTime = Date()
    private let frameDuration = CMTime(value: 1, timescale: 30)
    private var frameIndex: Int64 = 0
    private var isFinished = false
    private let outputURL: URL
    private let size: CGSize

    init(feedName: String, size: CGSize) throws {
        self.size = size
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KittenCam Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = feedName
            .replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        outputURL = directory.appendingPathComponent("\(safeName.isEmpty ? "KittenCam" : safeName)-\(formatter.string(from: Date())).mp4")

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
        )
        input.expectsMediaDataInRealTime = true

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )

        guard writer.canAdd(input) else {
            throw RecorderError.cannotAddInput
        }

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CGImage) {
        guard !isFinished, input.isReadyForMoreMediaData else {
            return
        }

        guard let pool = adaptor.pixelBufferPool else {
            return
        }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else {
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return
        }

        context.draw(image, in: CGRect(origin: .zero, size: size))
        let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
        if adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            frameIndex += 1
        }
    }

    func finish() async -> URL? {
        guard !isFinished else {
            return outputURL
        }

        isFinished = true
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        return writer.status == .completed ? outputURL : nil
    }

    private enum RecorderError: LocalizedError {
        case cannotAddInput

        var errorDescription: String? {
            "The recorder could not create a video track."
        }
    }
}
