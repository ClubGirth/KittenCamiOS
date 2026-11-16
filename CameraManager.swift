import AVFoundation
import Combine
import CoreMedia
import Foundation
import SwiftUI

enum VideoResolution: String, CaseIterable, Identifiable {
    case p720 = "720p"
    case p1080 = "1080p"
    case p1440 = "1440p"
    case p4K = "4K"

    var id: String {
        rawValue
    }

    var width: Int32 {
        switch self {
        case .p720:
            return 1280

        case .p1080:
            return 1920

        case .p1440:
            return 2560

        case .p4K:
            return 3840
        }
    }

    var height: Int32 {
        switch self {
        case .p720:
            return 720

        case .p1080:
            return 1080

        case .p1440:
            return 1440

        case .p4K:
            return 2160
        }
    }

    var dimensionsText: String {
        "\(width) × \(height)"
    }
}

final class CameraManager: ObservableObject {
    let session = AVCaptureSession()

    // MARK: - Zoom

    @Published var selectedLens = "1×"
    @Published var zoomLevel: CGFloat = 1.0
    @Published var minimumZoom: CGFloat = 0.5
    @Published var maximumZoom: CGFloat = 15.0

    // MARK: - Torch

    @Published var torchEnabled = false
    @Published var torchLevel: Float = 0.5
    @Published var torchAvailable = false

    // MARK: - Microphone

    @Published var microphoneEnabled = true
    @Published var microphoneAuthorized = false

    @Published var activeMicrophoneModeName =
        "Wide capture"

    // MARK: - Video format

    @Published var selectedResolution: VideoResolution = .p1080
    @Published var selectedFPS = 30

    @Published var supportedVideoOptions:
        [VideoResolution: [Int]] = [:]

    @Published var isChangingVideoFormat = false

    // MARK: - Errors

    @Published var errorMessage: String?

    private let supportedFrameRates = [
        24,
        30,
        50,
        60
    ]

    private let sessionQueue = DispatchQueue(
        label: "com.zakk.KittenCam.camera-session"
    )

    private var currentInput: AVCaptureDeviceInput?
    private var currentDevice: AVCaptureDevice?

    private var currentAudioInput:
        AVCaptureDeviceInput?

    private var hasConfiguredSession = false

    private var microphoneModeTimer:
        DispatchSourceTimer?

    /*
     Receives raw camera frames on its own queue.
     Later, these frames will be passed into the H.264 encoder.
    */
    private let frameOutput = CameraFrameOutput()

    private let microphoneOutput =
        MicrophoneAudioOutput()

    /*
     Converts the zoom number displayed to the user into
     Apple's internal videoZoomFactor.
    */
    private var wideCameraReferenceFactor: CGFloat = 1.0

    // MARK: - Public format information

    func isResolutionAvailable(
        _ resolution: VideoResolution
    ) -> Bool {
        !(supportedVideoOptions[resolution] ?? []).isEmpty
    }

    func availableFrameRates(
        for resolution: VideoResolution
    ) -> [Int] {
        supportedVideoOptions[resolution] ?? []
    }

    func isFrameRateAvailable(
        _ fps: Int,
        for resolution: VideoResolution
    ) -> Bool {
        availableFrameRates(
            for: resolution
        ).contains(fps)
    }

    var activeFormatDescription: String {
        "\(selectedResolution.rawValue) • \(selectedFPS) FPS"
    }

    // MARK: - Camera lifecycle

    func start() {
        requestVideoPermission()
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.stopMicrophoneModeMonitoring()

            self.microphoneOutput
                .setEnabled(false)

            if self.session.isRunning {
                self.session.stopRunning()
            }

            do {
                try AVAudioSession
                    .sharedInstance()
                    .setActive(
                        false,
                        options:
                            .notifyOthersOnDeactivation
                    )
            } catch {
                print(
                    "KittenCam audio session could not deactivate: \(error.localizedDescription)"
                )
            }
        }
    }

    private func requestVideoPermission() {
        let status =
            AVCaptureDevice
                .authorizationStatus(
                    for: .video
                )

        switch status {
        case .authorized:
            requestMicrophonePermission()

        case .notDetermined:
            AVCaptureDevice.requestAccess(
                for: .video
            ) { [weak self] granted in
                guard let self else {
                    return
                }

                if granted {
                    self.requestMicrophonePermission()
                } else {
                    self.showError(
                        "Camera permission was denied."
                    )
                }
            }

        case .denied, .restricted:
            showError(
                "Camera access is disabled. Enable it in iPhone Settings."
            )

        @unknown default:
            showError(
                "The camera permission status could not be determined."
            )
        }
    }

    private func requestMicrophonePermission() {
        let status =
            AVCaptureDevice
                .authorizationStatus(
                    for: .audio
                )

        switch status {
        case .authorized:
            publishMicrophoneAuthorization(
                true
            )

            configureSessionIfNeeded(
                includeAudio: true
            )

        case .notDetermined:
            AVCaptureDevice.requestAccess(
                for: .audio
            ) { [weak self] granted in
                guard let self else {
                    return
                }

                self.publishMicrophoneAuthorization(
                    granted
                )

                self.configureSessionIfNeeded(
                    includeAudio: granted
                )
            }

        case .denied, .restricted:
            publishMicrophoneAuthorization(
                false
            )

            configureSessionIfNeeded(
                includeAudio: false
            )

        @unknown default:
            publishMicrophoneAuthorization(
                false
            )

            configureSessionIfNeeded(
                includeAudio: false
            )
        }
    }

    private func publishMicrophoneAuthorization(
        _ authorized: Bool
    ) {
        DispatchQueue.main.async {
            self.microphoneAuthorized =
                authorized

            if !authorized {
                self.microphoneEnabled =
                    false

                self.activeMicrophoneModeName =
                    "Permission denied"
            }
        }
    }

    // MARK: - Video format controls

    func selectResolution(
        _ resolution: VideoResolution
    ) {
        let frameRates = availableFrameRates(
            for: resolution
        )

        guard !frameRates.isEmpty else {
            showError(
                "\(resolution.rawValue) is not available on this camera."
            )
            return
        }

        let fps: Int

        if frameRates.contains(selectedFPS) {
            fps = selectedFPS
        } else if frameRates.contains(30) {
            fps = 30
        } else if frameRates.contains(24) {
            fps = 24
        } else {
            fps = frameRates[0]
        }

        setVideoFormat(
            resolution: resolution,
            fps: fps
        )
    }

    func selectFrameRate(
        _ fps: Int
    ) {
        guard isFrameRateAvailable(
            fps,
            for: selectedResolution
        ) else {
            showError(
                "\(fps) FPS is not available at \(selectedResolution.rawValue)."
            )
            return
        }

        setVideoFormat(
            resolution: selectedResolution,
            fps: fps
        )
    }

    /*
     This is the reusable function the desktop controller
     will call later.
    */
    func setVideoFormat(
        resolution: VideoResolution,
        fps: Int
    ) {
        DispatchQueue.main.async {
            self.isChangingVideoFormat = true
        }

        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard let device = self.currentDevice else {
                self.finishFormatChange()
                return
            }

            guard let format = self.findFormat(
                for: device,
                resolution: resolution,
                fps: fps
            ) else {
                self.finishFormatChange(
                    error:
                        "\(resolution.rawValue) at \(fps) FPS is not supported."
                )
                return
            }

            let previousZoom = self.zoomLevel
            let previousTorchEnabled = self.torchEnabled
            let previousTorchLevel = self.torchLevel

            do {
                self.session.beginConfiguration()

                try device.lockForConfiguration()

                device.activeFormat = format

                let frameDuration = CMTime(
                    value: 1,
                    timescale: CMTimeScale(fps)
                )

                device.activeVideoMinFrameDuration =
                    frameDuration

                device.activeVideoMaxFrameDuration =
                    frameDuration

                self.configureAutomaticCameraBehavior(
                    for: device
                )

                device.unlockForConfiguration()

                self.session.commitConfiguration()

                self.configureZoomRange(
                    for: device
                )

                self.frameOutput.setTargetFrameRate(fps)

                DispatchQueue.main.async {
                    self.selectedResolution = resolution
                    self.selectedFPS = fps
                    self.isChangingVideoFormat = false
                    self.errorMessage = nil
                }

                self.setZoom(previousZoom)

                if previousTorchEnabled {
                    self.setTorch(
                        enabled: true,
                        level: previousTorchLevel
                    )
                }
            } catch {
                self.session.commitConfiguration()

                self.finishFormatChange(
                    error:
                        "Video format could not be changed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func discoverSupportedVideoOptions(
        for device: AVCaptureDevice
    ) -> [VideoResolution: [Int]] {
        var results:
            [VideoResolution: Set<Int>] = [:]

        for resolution in VideoResolution.allCases {
            results[resolution] = []
        }

        for format in device.formats {
            let dimensions =
                CMVideoFormatDescriptionGetDimensions(
                    format.formatDescription
                )

            guard let resolution =
                    resolutionMatching(
                        dimensions: dimensions
                    ) else {
                continue
            }

            for fps in supportedFrameRates {
                if formatSupports(
                    format,
                    fps: fps
                ) {
                    results[resolution]?.insert(fps)
                }
            }
        }

        var finished:
            [VideoResolution: [Int]] = [:]

        for resolution in VideoResolution.allCases {
            finished[resolution] =
                Array(results[resolution] ?? [])
                    .sorted()
        }

        return finished
    }

    private func findFormat(
        for device: AVCaptureDevice,
        resolution: VideoResolution,
        fps: Int
    ) -> AVCaptureDevice.Format? {
        let matchingFormats =
            device.formats.filter { format in
                let dimensions =
                    CMVideoFormatDescriptionGetDimensions(
                        format.formatDescription
                    )

                return dimensions.width ==
                    resolution.width &&
                    dimensions.height ==
                    resolution.height &&
                    formatSupports(
                        format,
                        fps: fps
                    )
            }

        /*
         Prefer a format whose supported maximum frame rate
         is closest to the requested rate.
        */
        return matchingFormats.min { first, second in
            maximumFPS(for: first) <
                maximumFPS(for: second)
        }
    }

    private func resolutionMatching(
        dimensions: CMVideoDimensions
    ) -> VideoResolution? {
        VideoResolution.allCases.first { resolution in
            dimensions.width == resolution.width &&
                dimensions.height == resolution.height
        }
    }

    private func formatSupports(
        _ format: AVCaptureDevice.Format,
        fps: Int
    ) -> Bool {
        let requestedFPS = Double(fps)

        return format.videoSupportedFrameRateRanges.contains {
            range in

            requestedFPS >= range.minFrameRate &&
                requestedFPS <= range.maxFrameRate
        }
    }

    private func maximumFPS(
        for format: AVCaptureDevice.Format
    ) -> Double {
        format.videoSupportedFrameRateRanges
            .map(\.maxFrameRate)
            .max() ?? 0
    }

    private func chooseInitialFormat(
        from options: [VideoResolution: [Int]]
    ) -> (
        resolution: VideoResolution,
        fps: Int
    )? {
        let preferences: [
            (VideoResolution, Int)
        ] = [
            (.p1080, 30),
            (.p1080, 60),
            (.p4K, 30),
            (.p720, 30),
            (.p720, 60),
            (.p1440, 30)
        ]

        for preference in preferences {
            let frameRates =
                options[preference.0] ?? []

            if frameRates.contains(preference.1) {
                return preference
            }
        }

        for resolution in VideoResolution.allCases {
            if let firstFPS =
                options[resolution]?.first {
                return (
                    resolution,
                    firstFPS
                )
            }
        }

        return nil
    }

    private func finishFormatChange(
        error: String? = nil
    ) {
        DispatchQueue.main.async {
            self.isChangingVideoFormat = false

            if let error {
                self.errorMessage = error
            }
        }
    }

    // MARK: - Zoom controls

    func setZoom(
        _ requestedZoom: CGFloat
    ) {
        sessionQueue.async { [weak self] in
            guard let self,
                  let device = self.currentDevice else {
                return
            }

            let displayZoom =
                self.clampDisplayZoom(
                    requestedZoom
                )

            let deviceZoom =
                self.clampDeviceZoom(
                    displayZoom *
                        self.wideCameraReferenceFactor,
                    for: device
                )

            do {
                try device.lockForConfiguration()

                device.cancelVideoZoomRamp()
                device.videoZoomFactor = deviceZoom

                device.unlockForConfiguration()

                self.publishZoom(displayZoom)
            } catch {
                self.showError(
                    "Zoom could not be changed: \(error.localizedDescription)"
                )
            }
        }
    }

    func smoothZoom(
        to requestedZoom: CGFloat,
        rate: Float = 2.0
    ) {
        sessionQueue.async { [weak self] in
            guard let self,
                  let device = self.currentDevice else {
                return
            }

            let displayZoom =
                self.clampDisplayZoom(
                    requestedZoom
                )

            let deviceZoom =
                self.clampDeviceZoom(
                    displayZoom *
                        self.wideCameraReferenceFactor,
                    for: device
                )

            do {
                try device.lockForConfiguration()

                device.ramp(
                    toVideoZoomFactor: deviceZoom,
                    withRate: rate
                )

                device.unlockForConfiguration()

                self.publishZoom(displayZoom)
            } catch {
                self.showError(
                    "Smooth zoom failed: \(error.localizedDescription)"
                )
            }
        }
    }

    func stopSmoothZoom() {
        sessionQueue.async { [weak self] in
            guard let self,
                  let device = self.currentDevice else {
                return
            }

            do {
                try device.lockForConfiguration()
                device.cancelVideoZoomRamp()
                device.unlockForConfiguration()
            } catch {
                self.showError(
                    "Zoom could not be stopped."
                )
            }
        }
    }

    // MARK: - Torch controls

    func setTorch(
        enabled: Bool,
        level requestedLevel: Float? = nil
    ) {
        sessionQueue.async { [weak self] in
            guard let self,
                  let device = self.currentDevice else {
                return
            }

            guard device.hasTorch,
                  device.isTorchAvailable else {
                self.showError(
                    "The torch is not currently available."
                )
                return
            }

            let level = min(
                max(
                    requestedLevel ??
                        self.torchLevel,
                    0.01
                ),
                1.0
            )

            do {
                try device.lockForConfiguration()

                if enabled {
                    try device.setTorchModeOn(
                        level: level
                    )
                } else {
                    device.torchMode = .off
                }

                device.unlockForConfiguration()

                DispatchQueue.main.async {
                    self.torchEnabled = enabled
                    self.torchLevel = level
                    self.errorMessage = nil
                }
            } catch {
                self.showError(
                    "Torch control failed: \(error.localizedDescription)"
                )
            }
        }
    }

    func setTorchLevel(
        _ requestedLevel: Float
    ) {
        let level = min(
            max(requestedLevel, 0.01),
            1.0
        )

        DispatchQueue.main.async {
            self.torchLevel = level
        }

        if torchEnabled {
            setTorch(
                enabled: true,
                level: level
            )
        }
    }

    func toggleTorch() {
        setTorch(
            enabled: !torchEnabled,
            level: torchLevel
        )
    }


    // MARK: - Microphone controls

    func setMicrophoneEnabled(
        _ enabled: Bool
    ) {
        guard microphoneAuthorized else {
            showError(
                "Microphone access is disabled. Enable it in iPhone Settings."
            )

            return
        }

        microphoneOutput
            .setEnabled(enabled)

        DispatchQueue.main.async {
            self.microphoneEnabled =
                enabled

            self.errorMessage = nil
        }

        if enabled {
            refreshMicrophoneModeStatus()
        }
    }

    func toggleMicrophone() {
        setMicrophoneEnabled(
            !microphoneEnabled
        )
    }

    private func configureAudioSession()
        throws {
        let audioSession =
            AVAudioSession.sharedInstance()

        let options:
            AVAudioSession.CategoryOptions = [
                .allowBluetoothHFP,
                .defaultToSpeaker
            ]

        /*
         Play-and-record keeps microphone capture active while
         allowing talkback audio from a control device to come
         through the viewing device speaker.
        */
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: options
        )

        try audioSession.setPreferredSampleRate(
            48_000
        )

        try audioSession.setPreferredIOBufferDuration(
            0.01
        )

        try audioSession.setActive(
            true
        )
    }

    private func addMicrophoneCaptureIfPossible(
        includeAudio: Bool
    ) -> Bool {
        guard includeAudio else {
            return false
        }

        do {
            try configureAudioSession()

            guard let microphone =
                    AVCaptureDevice.default(
                        for: .audio
                    )
            else {
                publishMicrophoneFailure(
                    "No microphone input was found."
                )

                return false
            }

            let audioInput =
                try AVCaptureDeviceInput(
                    device: microphone
                )

            guard session.canAddInput(
                audioInput
            ) else {
                publishMicrophoneFailure(
                    "The microphone input could not be added."
                )

                return false
            }

            guard session.canAddOutput(
                microphoneOutput.output
            ) else {
                publishMicrophoneFailure(
                    "The microphone output could not be added."
                )

                return false
            }

            session.addInput(
                audioInput
            )

            session.addOutput(
                microphoneOutput.output
            )

            currentAudioInput =
                audioInput

            return true
        } catch {
            publishMicrophoneFailure(
                "The microphone could not start: \(error.localizedDescription)"
            )

            return false
        }
    }

    private func publishMicrophoneFailure(
        _ message: String
    ) {
        print(message)

        DispatchQueue.main.async {
            self.microphoneAuthorized =
                false

            self.microphoneEnabled =
                false

            self.activeMicrophoneModeName =
                "Unavailable"
        }
    }

    private func startMicrophoneModeMonitoring() {
        stopMicrophoneModeMonitoring()

        let timer =
            DispatchSource
                .makeTimerSource(
                    queue: sessionQueue
                )

        timer.schedule(
            deadline: .now(),
            repeating: 1
        )

        timer.setEventHandler {
            [weak self] in

            self?
                .refreshMicrophoneModeStatus()
        }

        microphoneModeTimer = timer
        timer.resume()
    }

    private func stopMicrophoneModeMonitoring() {
        microphoneModeTimer?.cancel()
        microphoneModeTimer = nil
    }

    private func refreshMicrophoneModeStatus() {
        let name: String

        if #available(iOS 15.0, *) {
            switch AVCaptureDevice
                .activeMicrophoneMode {
            case .wideSpectrum:
                name = "Wide Spectrum"

            case .voiceIsolation:
                name = "Voice Isolation"

            case .standard:
                name = "Standard"

            @unknown default:
                name = "Wide capture"
            }
        } else {
            name = "Wide capture"
        }

        DispatchQueue.main.async {
            self.activeMicrophoneModeName =
                name
        }
    }

    // MARK: - Session configuration

    private func configureSessionIfNeeded(
        includeAudio: Bool
    ) {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            if self.hasConfiguredSession {
                self.microphoneOutput
                    .setEnabled(
                        self.microphoneEnabled &&
                        self.microphoneAuthorized
                    )

                if !self.session.isRunning {
                    self.session.startRunning()
                }

                self.startMicrophoneModeMonitoring()

                return
            }

            guard let camera =
                    self.findBestCamera() else {
                self.showError(
                    "No compatible rear camera was found."
                )
                return
            }

            do {
                let input =
                    try AVCaptureDeviceInput(
                        device: camera
                    )

                self.session.beginConfiguration()

                /*
                 inputPriority tells AVFoundation that we will
                 choose the device format ourselves.
                */
                self.session.sessionPreset =
                    .inputPriority

                self.session
                    .automaticallyConfiguresApplicationAudioSession =
                    false

                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()

                    self.showError(
                        "The camera input could not be added."
                    )
                    return
                }

                self.session.addInput(input)

                guard self.session.canAddOutput(
                    self.frameOutput.output
                ) else {
                    self.session.commitConfiguration()

                    self.showError(
                        "The camera frame output could not be added."
                    )
                    return
                }

                self.session.addOutput(
                    self.frameOutput.output
                )

                let audioWasConfigured =
                    self.addMicrophoneCaptureIfPossible(
                        includeAudio:
                            includeAudio
                    )

                self.currentInput = input
                self.currentDevice = camera

                let options =
                    self.discoverSupportedVideoOptions(
                        for: camera
                    )

                guard let initialFormat =
                        self.chooseInitialFormat(
                            from: options
                        ),
                      let format =
                        self.findFormat(
                            for: camera,
                            resolution:
                                initialFormat.resolution,
                            fps: initialFormat.fps
                        ) else {
                    self.session.commitConfiguration()

                    self.showError(
                        "No compatible video format was found."
                    )
                    return
                }

                try camera.lockForConfiguration()

                camera.activeFormat = format

                let frameDuration = CMTime(
                    value: 1,
                    timescale:
                        CMTimeScale(
                            initialFormat.fps
                        )
                )

                camera.activeVideoMinFrameDuration =
                    frameDuration

                camera.activeVideoMaxFrameDuration =
                    frameDuration

                self.configureAutomaticCameraBehavior(
                    for: camera
                )

                camera.unlockForConfiguration()

                self.hasConfiguredSession = true

                self.frameOutput.setTargetFrameRate(
                    initialFormat.fps
                )

                self.microphoneOutput
                    .setEnabled(
                        audioWasConfigured
                    )

                self.configureZoomRange(
                    for: camera
                )

                self.session.commitConfiguration()

                DispatchQueue.main.async {
                    self.supportedVideoOptions =
                        options

                    self.selectedResolution =
                        initialFormat.resolution

                    self.selectedFPS =
                        initialFormat.fps

                    self.torchAvailable =
                        camera.hasTorch &&
                        camera.isTorchAvailable

                    self.microphoneAuthorized =
                        audioWasConfigured

                    self.microphoneEnabled =
                        audioWasConfigured
                }

                self.session.startRunning()
                self.startMicrophoneModeMonitoring()
                self.refreshMicrophoneModeStatus()
                self.setZoom(1.0)
            } catch {
                self.session.commitConfiguration()

                self.showError(
                    "The camera could not start: \(error.localizedDescription)"
                )
            }
        }
    }

    private func configureAutomaticCameraBehavior(
        for device: AVCaptureDevice
    ) {
        if device.isFocusModeSupported(
            .continuousAutoFocus
        ) {
            device.focusMode =
                .continuousAutoFocus
        }

        if device.isExposureModeSupported(
            .continuousAutoExposure
        ) {
            device.exposureMode =
                .continuousAutoExposure
        }

        if device.isWhiteBalanceModeSupported(
            .continuousAutoWhiteBalance
        ) {
            device.whiteBalanceMode =
                .continuousAutoWhiteBalance
        }
    }

    private func findBestCamera()
        -> AVCaptureDevice? {
        if let tripleCamera =
            AVCaptureDevice.default(
                .builtInTripleCamera,
                for: .video,
                position: .back
            ) {
            return tripleCamera
        }

        if let dualWideCamera =
            AVCaptureDevice.default(
                .builtInDualWideCamera,
                for: .video,
                position: .back
            ) {
            return dualWideCamera
        }

        if let dualCamera =
            AVCaptureDevice.default(
                .builtInDualCamera,
                for: .video,
                position: .back
            ) {
            return dualCamera
        }

        return AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        )
    }

    // MARK: - Zoom range configuration

    private func configureZoomRange(
        for device: AVCaptureDevice
    ) {
        let containsUltraWide =
            device.constituentDevices.contains {
                constituent in

                constituent.deviceType ==
                    .builtInUltraWideCamera
            }

        if containsUltraWide,
           let firstSwitchFactor =
                device
                    .virtualDeviceSwitchOverVideoZoomFactors
                    .first {
            wideCameraReferenceFactor =
                CGFloat(
                    truncating:
                        firstSwitchFactor
                )
        } else {
            wideCameraReferenceFactor = 1.0
        }

        let deviceMinimum =
            device.minAvailableVideoZoomFactor

        let deviceMaximum =
            device.maxAvailableVideoZoomFactor

        let calculatedMinimum =
            deviceMinimum /
                wideCameraReferenceFactor

        let calculatedMaximum =
            deviceMaximum /
                wideCameraReferenceFactor

        let sensibleMaximum = min(
            calculatedMaximum,
            15.0
        )

        DispatchQueue.main.async {
            self.minimumZoom =
                calculatedMinimum

            self.maximumZoom = max(
                calculatedMinimum,
                sensibleMaximum
            )

            self.torchAvailable =
                device.hasTorch &&
                device.isTorchAvailable
        }
    }

    private func clampDisplayZoom(
        _ zoom: CGFloat
    ) -> CGFloat {
        min(
            max(
                zoom,
                minimumZoom
            ),
            maximumZoom
        )
    }

    private func clampDeviceZoom(
        _ zoom: CGFloat,
        for device: AVCaptureDevice
    ) -> CGFloat {
        min(
            max(
                zoom,
                device.minAvailableVideoZoomFactor
            ),
            device.maxAvailableVideoZoomFactor
        )
    }

    private func publishZoom(
        _ displayZoom: CGFloat
    ) {
        DispatchQueue.main.async {
            self.zoomLevel = displayZoom

            self.selectedLens = String(
                format: "%.1f×",
                displayZoom
            )

            self.errorMessage = nil
        }
    }

    private func showError(
        _ message: String
    ) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.isChangingVideoFormat = false
        }
    }
}
