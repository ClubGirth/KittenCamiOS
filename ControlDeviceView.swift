import SwiftUI

struct ControlDeviceView: View {
    @StateObject private var model = ControlDeviceViewModel()
    @State private var fullscreenFeed: ControlFeedSession?
    @State private var isControlPanelCollapsed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.055)
                    .ignoresSafeArea()

                GeometryReader { proxy in
                    if proxy.size.width > proxy.size.height {
                        landscapeLayout
                    } else {
                        portraitLayout
                    }
                }
            }
            .navigationTitle("Control Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.isGridMode.toggle()
                    } label: {
                        Image(systemName: model.isGridMode ? "rectangle.grid.1x2" : "square.grid.2x2")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $fullscreenFeed) { feed in
            FullscreenFeedView(feed: feed) {
                fullscreenFeed = nil
            }
        }
        .onAppear {
            model.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            model.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .alert("KittenCam", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {
                model.message = nil
            }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            feedArea
                .frame(maxHeight: .infinity)

            ControlPanel(model: model)
                .frame(maxHeight: 360)
        }
    }

    private var landscapeLayout: some View {
        GeometryReader { proxy in
            let toggleWidth: CGFloat = 44
            let panelWidth = max(300, (proxy.size.width - toggleWidth) * 0.40)
            let feedWidth = isControlPanelCollapsed
                ? proxy.size.width - toggleWidth
                : proxy.size.width - panelWidth - toggleWidth

            HStack(spacing: 0) {
                feedArea
                    .frame(width: feedWidth)

                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        isControlPanelCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isControlPanelCollapsed ? "chevron.left" : "chevron.right")
                        .font(.headline.weight(.bold))
                        .frame(width: 34, height: 58)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel(isControlPanelCollapsed ? "Show controls" : "Hide controls")
                .frame(width: toggleWidth)

                if !isControlPanelCollapsed {
                    ControlPanel(model: model)
                        .frame(width: panelWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    private var feedArea: some View {
        VStack(spacing: 10) {
            headerBar

            if model.connectedFeeds.isEmpty {
                emptyPreview
            } else if model.isGridMode {
                gridFeeds
            } else if let feed = model.selectedFeed ?? model.connectedFeeds.first {
                FeedCard(feed: feed, model: model, isLarge: true) {
                    fullscreenFeed = feed
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.top, 8)
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedFeed?.name ?? "No feed selected")
                    .font(.headline)
                    .lineLimit(1)

                Text(model.selectedFeed?.formatText ?? "Discovering local cameras")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.refreshDiscovery()
            } label: {
                Group {
                    if model.discovery.isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.08))
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
    }

    private var emptyPreview: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.cyan)

            Text("Choose a KittenCam camera below")
                .font(.headline)

            Text("Devices appear automatically when the viewing device app is open on the same local network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    private var gridFeeds: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(model.connectedFeeds) { feed in
                    FeedCard(feed: feed, model: model, isLarge: false) {
                        fullscreenFeed = feed
                    }
                    .frame(height: 180)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}

private struct FeedCard: View {
    @ObservedObject var feed: ControlFeedSession
    @ObservedObject var model: ControlDeviceViewModel
    let isLarge: Bool
    let onFullscreen: () -> Void

    @GestureState private var magnification = 1.0
    @GestureState private var dragTranslation = CGSize.zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.black)

            feedImage
                .scaleEffect(feed.hoverZoomScale * magnification)
                .offset(
                    x: feed.panOffset.width + dragTranslation.width,
                    y: feed.panOffset.height + dragTranslation.height
                )
                .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.86), value: feed.hoverZoomScale)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(feed.streamClient.statistics.connected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)

                    Text(feed.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)

                    Spacer()

                    if feed.isRecording {
                        Label("REC", systemImage: "record.circle.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.red)
                    }
                }

                Text(feed.streamClient.stateText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(10)
            .background(.linearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom))

            VStack {
                Spacer()
                HStack {
                    Button {
                        model.toggleRecording(for: feed)
                    } label: {
                        Image(systemName: feed.isRecording ? "stop.fill" : "record.circle")
                    }

                    Spacer()

                    Button {
                        onFullscreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }

                }
                .font(.headline)
                .padding(10)
                .background(.linearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom))
            }
            .opacity(isLarge ? 1 : 0.95)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(model.selectedFeedID == feed.id ? Color.cyan : Color.white.opacity(0.1), lineWidth: model.selectedFeedID == feed.id ? 2 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectFeed(feed)
        }
        .gesture(pinchGesture.simultaneously(with: panGesture))
        .clipped()
        .padding(.bottom, isLarge ? 12 : 0)
    }

    private var feedImage: some View {
        Group {
            if let image = feed.streamClient.latestImage {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(feed.streamClient.stateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($magnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                feed.hoverZoomScale = min(max(feed.hoverZoomScale * value, 1), 4)
                if feed.hoverZoomScale <= 1.01 {
                    feed.hoverZoomScale = 1
                    feed.panOffset = .zero
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragTranslation) { value, state, _ in
                guard feed.hoverZoomScale * magnification > 1.01 else {
                    state = .zero
                    return
                }

                state = value.translation
            }
            .onEnded { value in
                guard feed.hoverZoomScale > 1.01 else {
                    feed.panOffset = .zero
                    return
                }

                feed.panOffset.width += value.translation.width
                feed.panOffset.height += value.translation.height
            }
    }
}

private struct FullscreenFeedView: View {
    @ObservedObject var feed: ControlFeedSession
    let onClose: () -> Void

    @GestureState private var magnification = 1.0
    @GestureState private var dragTranslation = CGSize.zero

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            feedImage
                .scaleEffect(feed.hoverZoomScale * magnification)
                .offset(
                    x: feed.panOffset.width + dragTranslation.width,
                    y: feed.panOffset.height + dragTranslation.height
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(pinchGesture.simultaneously(with: panGesture))

            VStack {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(feed.name)
                            .font(.headline)
                            .lineLimit(1)

                        Text(feed.formatText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.72))
                    }

                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 34)
                .background(.linearGradient(colors: [.black.opacity(0.78), .clear], startPoint: .top, endPoint: .bottom))

                Spacer()

                HStack(spacing: 10) {
                    Circle()
                        .fill(feed.streamClient.statistics.connected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)

                    Text(feed.streamClient.stateText)
                        .font(.caption.monospacedDigit())

                    if feed.isRecording {
                        Text("REC")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.red)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 18)
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
    }

    private var feedImage: some View {
        Group {
            if let image = feed.streamClient.latestImage {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text(feed.streamClient.stateText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($magnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                feed.hoverZoomScale = min(max(feed.hoverZoomScale * value, 1), 4)
                if feed.hoverZoomScale <= 1.01 {
                    feed.hoverZoomScale = 1
                    feed.panOffset = .zero
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragTranslation) { value, state, _ in
                guard feed.hoverZoomScale * magnification > 1.01 else {
                    state = .zero
                    return
                }

                state = value.translation
            }
            .onEnded { value in
                guard feed.hoverZoomScale > 1.01 else {
                    feed.panOffset = .zero
                    return
                }

                feed.panOffset.width += value.translation.width
                feed.panOffset.height += value.translation.height
            }
    }
}

private struct PushToTalkButton: View {
    @ObservedObject var feed: ControlFeedSession
    @ObservedObject var model: ControlDeviceViewModel
    @GestureState private var isPressing = false

    var body: some View {
        Text(feed.isTalkBackEnabled ? "Talking..." : "Hold to Talk")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(buttonBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(feed.isTalkBackEnabled ? Color.cyan.opacity(0.7) : Color.white.opacity(0.14), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(pressGesture)
    }

    private var buttonBackground: Color {
        if feed.isTalkBackEnabled || isPressing {
            return Color.cyan.opacity(0.34)
        }

        return Color.white.opacity(0.10)
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPressing) { _, state, _ in
                state = true
            }
            .onChanged { _ in
                guard feed.device.talkBackAvailable,
                      !feed.isTalkBackEnabled else {
                    return
                }

                model.setTalkBack(enabled: true)
            }
            .onEnded { _ in
                model.setTalkBack(enabled: false)
            }
    }
}

private struct TalkBackStatusText: View {
    @ObservedObject var feed: ControlFeedSession
    @ObservedObject var sender: TalkBackAudioSender

    init(feed: ControlFeedSession) {
        self.feed = feed
        self.sender = feed.talkBackSender
    }

    var body: some View {
        Text(statusText)
            .font(.caption2)
            .foregroundStyle(sender.lastError == nil ? Color.secondary : Color.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusText: String {
        if let error = sender.lastError {
            return error
        }

        if sender.isSending {
            return "Speaking through the viewing device speaker. Monitoring is muted while held."
        }

        return feed.device.talkBackAvailable
            ? "Hold to speak through the viewing device speaker."
            : "Waiting for talkback service."
    }
}

private struct ControlPanel: View {
    @ObservedObject var model: ControlDeviceViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                camerasSection

                if let feed = model.selectedFeed {
                    selectedFeedSection(feed)
                    zoomSection
                    torchSection(feed)
                    microphoneSection(feed)
                    recordingSection(feed)
                    formatSection
                    statisticsSection(feed)
                }
            }
            .padding(14)
        }
        .background(.black.opacity(0.22))
    }

    private var camerasSection: some View {
        panelCard {
            HStack {
                Label("Cameras", systemImage: "camera.viewfinder")
                    .font(.headline)

                Spacer()

                Button {
                    model.refreshDiscovery()
                } label: {
                    if model.discovery.isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.08))
                .clipShape(Circle())
            }

            if model.discovery.devices.isEmpty {
                Text(model.discovery.isSearching ? "Searching..." : "No KittenCam devices found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(model.discovery.devices) { device in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)

                            Text(cameraStatusText(device))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if model.connectedFeeds.contains(where: { $0.id == device.id }) {
                            Button("Disconnect") {
                                model.disconnect(deviceID: device.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                        } else {
                            Button("Connect") {
                                model.connect(device)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func cameraStatusText(_ device: ControlCameraDevice) -> String {
        let videoText = device.videoAvailable ? "video ready" : "waiting for video"
        let talkText = device.talkBackAvailable ? "talk ready" : "waiting for talk"
        return "\(device.commandEndpoint?.displayAddress ?? "Unknown") • \(videoText) • \(talkText)"
    }

    private func selectedFeedSection(_ feed: ControlFeedSession) -> some View {
        panelCard {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(feed.name)
                        .font(.headline)
                    Text(feed.formatText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    model.disconnect(feed)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var zoomSection: some View {
        panelCard {
            HStack {
                Label("Zoom", systemImage: "plus.magnifyingglass")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.1f×", model.zoomDraft))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }

            Slider(value: Binding(get: { model.zoomDraft }, set: { model.queueZoom($0) }), in: 0.5...15, step: 0.1)

            HStack(spacing: 8) {
                ForEach([0.5, 1.0, 3.0], id: \.self) { zoom in
                    Button(String(format: zoom == 1 ? "%.0f×" : "%.1f×", zoom)) {
                        model.applyZoomPreset(zoom)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func torchSection(_ feed: ControlFeedSession) -> some View {
        panelCard {
            HStack {
                Label("Torch", systemImage: feed.status?.torchEnabled == true ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(get: { feed.status?.torchEnabled == true }, set: { model.setTorch(enabled: $0) }))
                    .labelsHidden()
            }

            Slider(value: Binding(get: { model.torchLevelDraft }, set: { model.queueTorchLevel($0) }), in: 0.01...1.0)
                .disabled(feed.status?.torchEnabled != true)

            Text("\(Int(model.torchLevelDraft * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func microphoneSection(_ feed: ControlFeedSession) -> some View {
        panelCard {
            HStack {
                Label("Microphone", systemImage: feed.isMonitoringAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(get: { feed.isMonitoringAudio }, set: { model.setMonitoring(enabled: $0) }))
                    .labelsHidden()
                    .disabled(feed.status?.microphoneAuthorized == false)
            }

            HStack {
                Text(feed.status?.microphoneMode ?? "Audio monitoring")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(feed.status?.microphoneEnabled == true ? "Remote On" : "Remote Off") {
                    model.setRemoteMicrophone(enabled: !(feed.status?.microphoneEnabled == true))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(feed.status?.microphoneAuthorized == false)
            }

            Divider()
                .opacity(0.25)

            VStack(alignment: .leading, spacing: 8) {
                Label("Talkback", systemImage: feed.isTalkBackEnabled ? "mic.fill" : "mic")
                    .font(.subheadline.weight(.semibold))

                PushToTalkButton(feed: feed, model: model)
                    .disabled(!feed.device.talkBackAvailable)
            }

            TalkBackStatusText(feed: feed)
        }
    }

    private func recordingSection(_ feed: ControlFeedSession) -> some View {
        panelCard {
            HStack {
                Label("Recording", systemImage: feed.isRecording ? "record.circle.fill" : "record.circle")
                    .font(.headline)
                    .foregroundStyle(feed.isRecording ? .red : .primary)

                Spacer()

                Button(feed.isRecording && feed.recordingReason == .manual ? "Stop" : "Record") {
                    model.toggleRecording(for: feed)
                }
                .buttonStyle(.borderedProminent)
                .tint(feed.isRecording ? .red : .blue)
            }

            HStack {
                Text("Motion-triggered")
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: Binding(get: { feed.motionRecordingEnabled }, set: { model.setMotionRecording($0) }))
                    .labelsHidden()
            }

            if feed.motionRecordingEnabled {
                Picker("Sensitivity", selection: Binding(get: { feed.motionSensitivity }, set: { model.updateMotionSensitivity($0) })) {
                    ForEach(MotionSensitivity.allCases) { sensitivity in
                        Text(sensitivity.rawValue).tag(sensitivity)
                    }
                }
                .pickerStyle(.segmented)

                Stepper(value: Binding(get: { feed.motionMinimumDuration }, set: { model.updateMotionMinimumDuration($0) }), in: 1...600, step: 1) {
                    Text("Minimum clip: \(Int(feed.motionMinimumDuration))s")
                        .font(.caption)
                }

                ProgressView(value: feed.motionLevel, total: 0.4)
                    .tint(feed.motionLevel >= feed.motionSensitivity.threshold ? .red : .green)
            }

            if let url = feed.lastRecordingURL {
                Text(url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Saved to Documents/KittenCam Recordings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var formatSection: some View {
        panelCard {
            Label("Video Format", systemImage: "video.fill")
                .font(.headline)

            Picker("Resolution", selection: Binding(get: { model.selectedResolution }, set: { model.selectedResolution = $0; model.sendVideoFormat() })) {
                ForEach(["720p", "1080p", "1440p", "4K"], id: \.self) { resolution in
                    Text(resolution).tag(resolution)
                }
            }
            .pickerStyle(.segmented)

            Picker("FPS", selection: Binding(get: { model.selectedFPS }, set: { model.selectedFPS = $0; model.sendVideoFormat() })) {
                ForEach([24, 30, 50, 60], id: \.self) { fps in
                    Text("\(fps)").tag(fps)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func statisticsSection(_ feed: ControlFeedSession) -> some View {
        panelCard {
            Label("Stream", systemImage: "waveform.path.ecg")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                statRow("Packets", "\(feed.streamClient.statistics.packets)")
                statRow("Video", "\(feed.streamClient.statistics.videoFrames) frames")
                statRow("Audio", "\(feed.streamClient.statistics.audioFrames) frames")
                statRow("Decoded", "\(feed.streamClient.statistics.decodedFrames)")
                statRow("Dropped", "\(feed.streamClient.statistics.droppedFrames)")
            }
            .font(.caption.monospacedDigit())
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func panelCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    ControlDeviceView()
}
