import AVFoundation
import CoreMedia
import Foundation

final class CameraFrameOutput:
    NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable {

    let output = AVCaptureVideoDataOutput()

    private let encoder =
        H264VideoEncoder()

    private let outputQueue = DispatchQueue(
        label: "com.zakk.KittenCam.camera-frame-output",
        qos: .userInteractive
    )

    private var targetFrameRate = 30
    private var frameCount = 0
    private var encodedFrameCount = 0

    private var lastReportedWidth = 0
    private var lastReportedHeight = 0
    private var lastReportedFrameRate = 0

    private var measurementStartTime =
        CFAbsoluteTimeGetCurrent()

    override init() {
        super.init()

        output.alwaysDiscardsLateVideoFrames = true

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]

        output.setSampleBufferDelegate(
            self,
            queue: outputQueue
        )

        encoder.onVideoConfiguration = {
            payload in

            VideoStreamServer.shared.broadcast(
                type: .videoConfiguration,
                payload: payload
            )

            print(
                "KittenCam sent H.264 SPS/PPS configuration."
            )
        }

        encoder.onVideoFrame = {
            [weak self] payload in

            VideoStreamServer.shared.broadcast(
                type: .videoFrame,
                payload: payload
            )

            self?.encodedFrameCount += 1
        }

        encoder.onError = {
            message in

            print(
                "KittenCam encoder error: \(message)"
            )
        }
    }

    func setTargetFrameRate(
        _ fps: Int
    ) {
        outputQueue.async { [weak self] in
            self?.targetFrameRate =
                max(fps, 1)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(
            sampleBuffer
        ) else {
            return
        }

        frameCount += 1

        reportStreamFormatIfNeeded(
            sampleBuffer
        )

        encoder.encode(
            sampleBuffer: sampleBuffer,
            targetFrameRate:
                targetFrameRate
        )

        reportPerformanceIfNeeded()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        print(
            "KittenCam dropped a camera frame."
        )
    }

    private func reportStreamFormatIfNeeded(
        _ sampleBuffer: CMSampleBuffer
    ) {
        guard let imageBuffer =
                CMSampleBufferGetImageBuffer(
                    sampleBuffer
                )
        else {
            return
        }

        let width =
            CVPixelBufferGetWidth(
                imageBuffer
            )

        let height =
            CVPixelBufferGetHeight(
                imageBuffer
            )

        guard
            width != lastReportedWidth ||
            height != lastReportedHeight ||
            targetFrameRate !=
                lastReportedFrameRate
        else {
            return
        }

        lastReportedWidth = width
        lastReportedHeight = height
        lastReportedFrameRate =
            targetFrameRate

        VideoStreamServer.shared
            .updateVideoFormat(
                width: width,
                height: height,
                fps: targetFrameRate
            )
    }

    private func reportPerformanceIfNeeded() {
        let currentTime =
            CFAbsoluteTimeGetCurrent()

        let elapsed =
            currentTime -
            measurementStartTime

        guard elapsed >= 2.0 else {
            return
        }

        let capturedFPS =
            Double(frameCount) / elapsed

        let encodedFPS =
            Double(encodedFrameCount) /
            elapsed

        print(
            String(
                format:
                    "KittenCam capture %.1f FPS • encoded %.1f FPS",
                capturedFPS,
                encodedFPS
            )
        )

        frameCount = 0
        encodedFrameCount = 0
        measurementStartTime = currentTime
    }
}
