import SwiftUI

struct ViewingDeviceView: View {
    @StateObject private var camera:
        CameraManager
    
    @StateObject private var commandServer:
        CameraCommandServer

    @State private var pinchStartZoom:
        CGFloat = 1.0

    @State private var controlsVisible =
        true

    @State private var showVideoSettings =
        false

    @State private var hideControlsTask:
        Task<Void, Never>?

    @Environment(\.verticalSizeClass)
    private var verticalSizeClass

    private var isLandscape: Bool {
        verticalSizeClass == .compact
    }

    
    init() {
        let camera = CameraManager()

        _camera = StateObject(
            wrappedValue: camera
        )

        _commandServer = StateObject(
            wrappedValue:
                CameraCommandServer(
                    camera: camera
                )
        )
    }
    
    var body: some View {
        ZStack {
            cameraPreview

            if controlsVisible {
                interfaceGradient
                    .transition(.opacity)

                cameraHUD
                    .transition(
                        .opacity.combined(
                            with:
                                .scale(
                                    scale: 0.98
                                )
                        )
                    )

                floatingZoomReadout
                    .transition(.opacity)
            }

            if camera.isChangingVideoFormat {
                formatChangingOverlay
            }

            if let errorMessage =
                camera.errorMessage {
                errorOverlay(
                    message: errorMessage
                )
            }
        }
        .background(.black)
        .statusBarHidden(true)
        .sheet(
            isPresented: $showVideoSettings
        ) {
            videoSettingsSheet
        }
        .onAppear {
            VideoStreamServer.shared.start()
            TalkBackAudioReceiverServer.shared.start()
            camera.start()
            commandServer.start()

            UIApplication.shared.isIdleTimerDisabled =
                true

            showControlsTemporarily()
        }
        .onDisappear {
            hideControlsTask?.cancel()

            commandServer.stop()
            camera.stop()
            TalkBackAudioReceiverServer.shared.stop()
            VideoStreamServer.shared.stop()

            UIApplication.shared.isIdleTimerDisabled =
                false
        }
    }

    // MARK: - Camera preview

    private var cameraPreview: some View {
        CameraPreview(
            session: camera.session
        )
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .simultaneousGesture(pinchGesture)
        .onTapGesture {
            showControlsTemporarily()
        }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                showControlsTemporarily()

                let newZoom =
                    pinchStartZoom *
                    magnification

                camera.setZoom(newZoom)
            }
            .onEnded { _ in
                pinchStartZoom =
                    camera.zoomLevel

                showControlsTemporarily()
            }
    }

    // MARK: - HUD

    private var cameraHUD: some View {
        VStack(spacing: 0) {
            topHUD

            Spacer()

            if isLandscape {
                landscapeBottomHUD
            } else {
                portraitBottomHUD
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var topHUD: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 120)

            HStack(spacing: 10) {
                formatPill
                statusPill
            }
        }
        .foregroundStyle(.white)
        .padding(
            .horizontal,
            isLandscape ? 24 : 18
        )
        .padding(
            .top,
            isLandscape ? 14 : 8
        )
        .shadow(radius: 4)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    commandServer.isRunning
                        ? Color.green
                        : Color.orange
                )
                .frame(
                    width: 8,
                    height: 8
                )

            VStack(
                alignment: .leading,
                spacing: 1
            ) {
                Text("KittenCam")
                    .font(.headline)
                    .fontWeight(.semibold)

                if let port = commandServer.port {
                    Text("Ready • Port \(port)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(
                            .white.opacity(0.75)
                        )
                } else {
                    Text("Starting network…")
                        .font(.caption2)
                        .foregroundStyle(
                            .white.opacity(0.75)
                        )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .background(.black.opacity(0.18))
        .clipShape(Capsule())
    }

    private var formatPill: some View {
        Text(camera.activeFormatDescription)
            .font(
                .caption.monospacedDigit()
            )
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                .ultraThinMaterial
            )
            .background(.black.opacity(0.18))
            .clipShape(Capsule())
    }

    // MARK: - Portrait HUD

    private var portraitBottomHUD: some View {
        VStack(spacing: 14) {
            bottomUtilityControls

            zoomButtons

            HStack(spacing: 12) {
                microphoneButton

                if camera.torchAvailable {
                    portraitTorchControls
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .background(.black.opacity(0.25))
        .clipShape(
            RoundedRectangle(
                cornerRadius: 24,
                style: .continuous
            )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 22)
    }

    private var portraitTorchControls:
        some View {
        HStack(spacing: 12) {
            torchButton

            Slider(
                value: torchBinding,
                in: 0.01...1.0
            )
            .disabled(!camera.torchEnabled)

            Text(
                "\(Int(camera.torchLevel * 100))%"
            )
            .font(
                .caption.monospacedDigit()
            )
            .foregroundStyle(.white)
            .frame(width: 40)
        }
    }

    // MARK: - Landscape HUD

    private var landscapeBottomHUD:
        some View {
        HStack(spacing: 12) {
            Spacer()

            bottomUtilityControls

            zoomButtons

            microphoneButton

            if camera.torchAvailable {
                landscapeTorchControls
            }

            Spacer()
        }
        .padding(.bottom, 12)
    }

    private var landscapeTorchControls:
        some View {
        HStack(spacing: 10) {
            torchButton

            Slider(
                value: torchBinding,
                in: 0.01...1.0
            )
            .frame(width: 120)
            .disabled(!camera.torchEnabled)

            Text(
                "\(Int(camera.torchLevel * 100))%"
            )
            .font(
                .caption.monospacedDigit()
            )
            .foregroundStyle(.white)
            .frame(width: 38)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .background(.black.opacity(0.25))
        .clipShape(Capsule())
    }

    // MARK: - Bottom utility controls

    private var bottomUtilityControls: some View {
        settingsButton
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .background(.black.opacity(0.25))
        .clipShape(Capsule())
    }

    private var settingsButton: some View {
        Button {
            hideControlsTask?.cancel()
            showVideoSettings = true
        } label: {
            Image(
                systemName:
                    "slider.horizontal.3"
            )
            .font(.headline)
            .frame(
                width: 34,
                height: 34
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var floatingZoomReadout: some View {
        Text(
            String(
                format: "%.1f×",
                camera.zoomLevel
            )
        )
        .font(
            .subheadline.monospacedDigit()
        )
        .fontWeight(.semibold)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .background(.black.opacity(0.22))
        .clipShape(Capsule())
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .bottomTrailing
        )
        .padding(.trailing, isLandscape ? 24 : 18)
        .padding(.bottom, isLandscape ? 78 : 188)
        .shadow(radius: 4)
    }

    // MARK: - Zoom controls

    private var zoomButtons: some View {
        HStack(spacing: 8) {
            presetButton(
                title: "0.5×",
                zoom: 0.5
            )

            presetButton(
                title: "1×",
                zoom: 1.0
            )

            presetButton(
                title: "3×",
                zoom: 3.0
            )
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .background(.black.opacity(0.25))
        .clipShape(Capsule())
    }

    private func presetButton(
        title: String,
        zoom: CGFloat
    ) -> some View {
        let selected =
            abs(
                camera.zoomLevel - zoom
            ) < 0.05

        return Button {
            camera.smoothZoom(to: zoom)
            pinchStartZoom = zoom
            showControlsTemporarily()
        } label: {
            Text(title)
                .font(
                    .headline
                        .monospacedDigit()
                )
                .fontWeight(.semibold)
                .foregroundStyle(
                    selected
                        ? .black
                        : .white
                )
                .frame(
                    width:
                        isLandscape
                            ? 56
                            : 64,
                    height:
                        isLandscape
                            ? 38
                            : 44
                )
                .background(
                    selected
                        ? Color.white
                        : Color.clear
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }


    // MARK: - Microphone controls

    private var microphoneButton:
        some View {
        Button {
            camera.toggleMicrophone()
            showControlsTemporarily()
        } label: {
            VStack(spacing: 2) {
                Image(
                    systemName:
                        camera.microphoneEnabled
                            ? "mic.fill"
                            : "mic.slash.fill"
                )
                .font(.headline)

                Text(
                    camera.microphoneEnabled
                        ? "Mic"
                        : "Muted"
                )
                .font(.caption2)
            }
            .foregroundStyle(
                camera.microphoneEnabled
                    ? .green
                    : .white
            )
            .frame(
                width:
                    isLandscape
                        ? 58
                        : 64,
                height:
                    isLandscape
                        ? 46
                        : 52
            )
            .background(
                .ultraThinMaterial
            )
            .background(
                .black.opacity(0.25)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(
            !camera.microphoneAuthorized
        )
        .opacity(
            camera.microphoneAuthorized
                ? 1.0
                : 0.45
        )
    }

    // MARK: - Torch controls

    private var torchButton: some View {
        Button {
            camera.toggleTorch()
            showControlsTemporarily()
        } label: {
            Image(
                systemName:
                    camera.torchEnabled
                        ? "flashlight.on.fill"
                        : "flashlight.off.fill"
            )
            .font(.headline)
            .foregroundStyle(
                camera.torchEnabled
                    ? .yellow
                    : .white
            )
            .frame(
                width: 42,
                height: 38
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var torchBinding:
        Binding<Double> {
        Binding(
            get: {
                Double(camera.torchLevel)
            },
            set: { newValue in
                camera.setTorchLevel(
                    Float(newValue)
                )

                showControlsTemporarily()
            }
        )
    }

    // MARK: - Video settings

    private var videoSettingsSheet:
        some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: 28
                ) {
                    currentFormatCard

                    resolutionSettings

                    frameRateSettings

                    microphoneSettings

                    formatExplanation
                }
                .padding(20)
            }
            .background(
                Color.black
                    .ignoresSafeArea()
            )
            .navigationTitle(
                "Video Quality"
            )
            .navigationBarTitleDisplayMode(
                .inline
            )
            .toolbar {
                ToolbarItem(
                    placement:
                        .confirmationAction
                ) {
                    Button("Done") {
                        showVideoSettings =
                            false

                        showControlsTemporarily()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents(
            isLandscape
                ? [.large]
                : [.medium, .large]
        )
        .presentationDragIndicator(
            .visible
        )
    }

    private var currentFormatCard:
        some View {
        HStack(spacing: 14) {
            Image(
                systemName:
                    "video.fill"
            )
            .font(.title2)
            .foregroundStyle(.green)
            .frame(
                width: 48,
                height: 48
            )
            .background(
                .green.opacity(0.15)
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 14
                )
            )

            VStack(
                alignment: .leading,
                spacing: 4
            ) {
                Text("Current format")
                    .font(.caption)
                    .foregroundStyle(
                        .secondary
                    )

                Text(
                    camera
                        .activeFormatDescription
                )
                .font(.headline)

                Text(
                    camera
                        .selectedResolution
                        .dimensionsText
                )
                .font(
                    .caption
                        .monospacedDigit()
                )
                .foregroundStyle(
                    .secondary
                )
            }

            Spacer()
        }
        .padding(16)
        .background(
            .white.opacity(0.08)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 20,
                style: .continuous
            )
        )
    }

    private var resolutionSettings:
        some View {
        VStack(
            alignment: .leading,
            spacing: 12
        ) {
            settingsHeader(
                title: "Resolution",
                subtitle:
                    "Only formats supported by this camera can be selected."
            )

            LazyVGrid(
                columns: [
                    GridItem(
                        .flexible()
                    ),
                    GridItem(
                        .flexible()
                    )
                ],
                spacing: 12
            ) {
                ForEach(
                    VideoResolution
                        .allCases
                ) { resolution in
                    resolutionButton(
                        resolution
                    )
                }
            }
        }
    }

    private func resolutionButton(
        _ resolution:
            VideoResolution
    ) -> some View {
        let available =
            camera.isResolutionAvailable(
                resolution
            )

        let selected =
            camera.selectedResolution ==
                resolution

        return Button {
            camera.selectResolution(
                resolution
            )
        } label: {
            VStack(spacing: 5) {
                HStack {
                    Text(
                        resolution.rawValue
                    )
                    .font(.headline)

                    Spacer()

                    if selected {
                        Image(
                            systemName:
                                "checkmark.circle.fill"
                        )
                        .foregroundStyle(
                            .green
                        )
                    }
                }

                HStack {
                    Text(
                        resolution
                            .dimensionsText
                    )
                    .font(
                        .caption
                            .monospacedDigit()
                    )

                    Spacer()

                    if !available {
                        Text("Unavailable")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(
                    available
                        ? .secondary
                        : .tertiary
                )
            }
            .padding(14)
            .frame(
                maxWidth: .infinity
            )
            .background(
                selected
                    ? Color.green
                        .opacity(0.16)
                    : Color.white
                        .opacity(0.07)
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: 16
                )
                .stroke(
                    selected
                        ? Color.green
                        : Color.white
                            .opacity(0.08),
                    lineWidth: 1
                )
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 16
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(
            available ? 1.0 : 0.45
        )
    }

    private var frameRateSettings:
        some View {
        VStack(
            alignment: .leading,
            spacing: 12
        ) {
            settingsHeader(
                title: "Frame rate",
                subtitle:
                    "Availability changes with the selected resolution."
            )

            HStack(spacing: 10) {
                ForEach(
                    [24, 30, 50, 60],
                    id: \.self
                ) { fps in
                    frameRateButton(fps)
                }
            }
        }
    }

    private func frameRateButton(
        _ fps: Int
    ) -> some View {
        let available =
            camera.isFrameRateAvailable(
                fps,
                for:
                    camera
                        .selectedResolution
            )

        let selected =
            camera.selectedFPS == fps

        return Button {
            camera.selectFrameRate(fps)
        } label: {
            VStack(spacing: 3) {
                Text("\(fps)")
                    .font(
                        .headline
                            .monospacedDigit()
                    )

                Text("FPS")
                    .font(.caption2)
            }
            .frame(
                maxWidth: .infinity
            )
            .padding(.vertical, 13)
            .foregroundStyle(
                selected
                    ? .black
                    : .white
            )
            .background(
                selected
                    ? Color.green
                    : Color.white
                        .opacity(0.08)
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 14
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(
            available ? 1.0 : 0.35
        )
    }

    private func settingsHeader(
        title: String,
        subtitle: String
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: 4
        ) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(
                    .secondary
                )
        }
    }


    private var microphoneSettings:
        some View {
        VStack(
            alignment: .leading,
            spacing: 12
        ) {
            settingsHeader(
                title: "Microphone",
                subtitle:
                    "Captures broad, minimally processed room audio at 48 kHz."
            )

            HStack(spacing: 14) {
                Image(
                    systemName:
                        camera.microphoneEnabled
                            ? "waveform.circle.fill"
                            : "mic.slash.circle.fill"
                )
                .font(.title2)
                .foregroundStyle(
                    camera.microphoneEnabled
                        ? .green
                        : .secondary
                )

                VStack(
                    alignment: .leading,
                    spacing: 3
                ) {
                    Text(
                        camera.microphoneEnabled
                            ? "Microphone streaming"
                            : "Microphone muted"
                    )
                    .font(.headline)

                    Text(
                        camera.activeMicrophoneModeName
                    )
                    .font(.caption)
                    .foregroundStyle(
                        .secondary
                    )
                }

                Spacer()

                Toggle(
                    "",
                    isOn:
                        Binding(
                            get: {
                                camera
                                    .microphoneEnabled
                            },
                            set: {
                                camera
                                    .setMicrophoneEnabled(
                                        $0
                                    )
                            }
                        )
                )
                .labelsHidden()
                .disabled(
                    !camera
                        .microphoneAuthorized
                )
            }
            .padding(16)
            .background(
                .white.opacity(0.07)
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 16
                )
            )

            Text(
                "KittenCam requests a wide, low-processing capture profile. Apple’s system Wide Spectrum Mic Mode is user-controlled; when selected, its active status appears above."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var formatExplanation:
        some View {
        VStack(
            alignment: .leading,
            spacing: 8
        ) {
            Label(
                "Higher resolutions and frame rates increase heat, battery usage and future network bandwidth.",
                systemImage:
                    "info.circle"
            )

            Text(
                "1440p is shown as unavailable when the camera does not provide an exact 2560 × 1440 capture format."
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(16)
        .background(
            .white.opacity(0.05)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 16
            )
        )
    }

    // MARK: - Visibility

    private func showControlsTemporarily() {
        hideControlsTask?.cancel()

        withAnimation(
            .easeInOut(duration: 0.2)
        ) {
            controlsVisible = true
        }

        hideControlsTask = Task {
            try? await Task.sleep(
                nanoseconds:
                    3_000_000_000
            )

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                withAnimation(
                    .easeInOut(
                        duration: 0.3
                    )
                ) {
                    controlsVisible =
                        false
                }
            }
        }
    }

    // MARK: - Styling

    private var interfaceGradient:
        some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    .black.opacity(0.6),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 120)

            Spacer()

            LinearGradient(
                colors: [
                    .clear,
                    .black.opacity(0.45)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 130)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var formatChangingOverlay:
        some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)

            Text("Changing video format…")
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial)
        .background(.black.opacity(0.35))
        .clipShape(
            RoundedRectangle(
                cornerRadius: 18
            )
        )
    }

    private func errorOverlay(
        message: String
    ) -> some View {
        VStack(spacing: 12) {
            Image(
                systemName:
                    "exclamationmark.triangle.fill"
            )
            .font(.title)
            .foregroundStyle(.yellow)

            Text("Camera Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(
                    .center
                )

            Button("Dismiss") {
                camera.errorMessage = nil
                showControlsTemporarily()
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.primary)
        .padding(24)
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 20,
                style: .continuous
            )
        )
        .padding(30)
    }
}

#Preview {
    ViewingDeviceView()
}
