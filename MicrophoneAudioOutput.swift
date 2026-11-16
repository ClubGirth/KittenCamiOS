import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

final class MicrophoneAudioOutput:
    NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable {

    let output =
        AVCaptureAudioDataOutput()

    private let outputQueue =
        DispatchQueue(
            label:
                "com.zakk.KittenCam.microphone-audio-output",
            qos: .userInteractive
        )

    private var isEnabled = true
    private var lastConfiguration:
        AudioConfigurationSignature?

    override init() {
        super.init()


        output.setSampleBufferDelegate(
            self,
            queue: outputQueue
        )
    }

    func setEnabled(
        _ enabled: Bool
    ) {
        outputQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.isEnabled = enabled

            if enabled {
                self.lastConfiguration = nil
            }

            VideoStreamServer.shared
                .updateAudioState(
                    enabled: enabled
                )
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isEnabled else {
            return
        }

        guard
            CMSampleBufferDataIsReady(
                sampleBuffer
            )
        else {
            return
        }

        guard
            reportConfigurationIfNeeded(
                sampleBuffer
            )
        else {
            return
        }

        guard
            let blockBuffer =
                CMSampleBufferGetDataBuffer(
                    sampleBuffer
                )
        else {
            print(
                "KittenCam microphone buffer did not contain PCM data."
            )

            return
        }

        let dataLength =
            CMBlockBufferGetDataLength(
                blockBuffer
            )

        guard dataLength > 0 else {
            return
        }

        var audioData =
            Data(count: dataLength)

        let copyStatus =
            audioData
                .withUnsafeMutableBytes {
                    rawBuffer in

                    guard
                        let destination =
                            rawBuffer
                                .baseAddress
                    else {
                        return
                            kCMBlockBufferBadCustomBlockSourceErr
                    }

                    return
                        CMBlockBufferCopyDataBytes(
                            blockBuffer,
                            atOffset: 0,
                            dataLength:
                                dataLength,
                            destination:
                                destination
                        )
                }

        guard
            copyStatus ==
                kCMBlockBufferNoErr
        else {
            print(
                "KittenCam microphone PCM copy failed with status \(copyStatus)."
            )

            return
        }

        let timestamp =
            CMSampleBufferGetPresentationTimeStamp(
                sampleBuffer
            )

        let timestampSeconds =
            CMTimeGetSeconds(
                timestamp
            )

        let timestampMicroseconds:
            UInt64

        if timestamp.isValid,
           timestampSeconds.isFinite,
           timestampSeconds >= 0 {
            timestampMicroseconds =
                UInt64(
                    timestampSeconds *
                    1_000_000
                )
        } else {
            timestampMicroseconds = 0
        }

        let sampleCount =
            max(
                CMSampleBufferGetNumSamples(
                    sampleBuffer
                ),
                0
            )

        var payload = Data()
        payload.reserveCapacity(
            12 + audioData.count
        )

        var networkTimestamp =
            timestampMicroseconds.bigEndian

        withUnsafeBytes(
            of: &networkTimestamp
        ) {
            payload.append(
                contentsOf: $0
            )
        }

        var networkSampleCount =
            UInt32(
                min(
                    sampleCount,
                    Int(UInt32.max)
                )
            ).bigEndian

        withUnsafeBytes(
            of: &networkSampleCount
        ) {
            payload.append(
                contentsOf: $0
            )
        }

        payload.append(audioData)

        VideoStreamServer.shared
            .broadcast(
                type: .audioFrame,
                payload: payload
            )
    }

    private func reportConfigurationIfNeeded(
        _ sampleBuffer: CMSampleBuffer
    ) -> Bool {
        guard
            let formatDescription =
                CMSampleBufferGetFormatDescription(
                    sampleBuffer
                ),
            let streamDescription =
                CMAudioFormatDescriptionGetStreamBasicDescription(
                    formatDescription
                )?
                .pointee
        else {
            print(
                "KittenCam could not read the microphone format."
            )

            return false
        }

        guard
            streamDescription.mFormatID ==
                kAudioFormatLinearPCM
        else {
            print(
                "KittenCam microphone output was not linear PCM."
            )

            return false
        }

        let signature =
            AudioConfigurationSignature(
                sampleRate:
                    streamDescription
                        .mSampleRate,

                channels:
                    streamDescription
                        .mChannelsPerFrame,

                bitsPerChannel:
                    streamDescription
                        .mBitsPerChannel,

                bytesPerFrame:
                    streamDescription
                        .mBytesPerFrame,

                formatFlags:
                    streamDescription
                        .mFormatFlags
            )

        guard
            signature !=
                lastConfiguration
        else {
            return true
        }

        lastConfiguration =
            signature

        let interleaved =
            (
                streamDescription
                    .mFormatFlags &
                kAudioFormatFlagIsNonInterleaved
            ) == 0

        let isFloat =
            (
                streamDescription
                    .mFormatFlags &
                kAudioFormatFlagIsFloat
            ) != 0

        let isBigEndian =
            (
                streamDescription
                    .mFormatFlags &
                kAudioFormatFlagIsBigEndian
            ) != 0

        let isSignedInteger =
            (
                streamDescription
                    .mFormatFlags &
                kAudioFormatFlagIsSignedInteger
            ) != 0

        let information:
            [String: Any] = [
                "codec":
                    "pcm_s16le",

                "format":
                    "linearPCM",

                "sampleRate":
                    streamDescription
                        .mSampleRate,

                "channels":
                    Int(
                        streamDescription
                            .mChannelsPerFrame
                    ),

                "bitsPerChannel":
                    Int(
                        streamDescription
                            .mBitsPerChannel
                    ),

                "bytesPerFrame":
                    Int(
                        streamDescription
                            .mBytesPerFrame
                    ),

                "interleaved":
                    interleaved,

                "isFloat":
                    isFloat,

                "isBigEndian":
                    isBigEndian,

                "isSignedInteger":
                    isSignedInteger,

                "packetHeaderBytes":
                    12,

                "timestampUnit":
                    "microseconds"
            ]

        guard
            JSONSerialization
                .isValidJSONObject(
                    information
                )
        else {
            return false
        }

        do {
            let configuration =
                try JSONSerialization
                    .data(
                        withJSONObject:
                            information
                    )

            VideoStreamServer.shared
                .updateAudioFormat(
                    sampleRate:
                        streamDescription
                            .mSampleRate,

                    channels:
                        Int(
                            streamDescription
                                .mChannelsPerFrame
                        ),

                    bitsPerChannel:
                        Int(
                            streamDescription
                                .mBitsPerChannel
                        )
                )

            VideoStreamServer.shared
                .updateAudioConfiguration(
                    configuration
                )

            print(
                "KittenCam microphone ready: \(Int(streamDescription.mSampleRate)) Hz, \(streamDescription.mChannelsPerFrame) channel, \(streamDescription.mBitsPerChannel)-bit PCM."
            )

            return true
        } catch {
            print(
                "KittenCam could not encode microphone configuration: \(error.localizedDescription)"
            )

            return false
        }
    }
}

private struct AudioConfigurationSignature:
    Equatable {

    let sampleRate: Double
    let channels: UInt32
    let bitsPerChannel: UInt32
    let bytesPerFrame: UInt32
    let formatFlags: AudioFormatFlags
}
