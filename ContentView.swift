import SwiftUI

struct ContentView: View {
    @State private var selectedMode: KittenCamMode?

    var body: some View {
        Group {
            switch selectedMode {
            case .viewing:
                ViewingDeviceView()
                    .overlay(alignment: .topLeading) {
                        modeBackButton
                    }

            case .control:
                ControlDeviceView()
                    .overlay(alignment: .topLeading) {
                        modeBackButton
                    }

            case nil:
                ModeSelectionView(selectedMode: $selectedMode)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedMode)
    }

    private var modeBackButton: some View {
        Button {
            selectedMode = nil
        } label: {
            Label("Modes", systemImage: "chevron.left")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.top, 12)
        .padding(.leading, 12)
    }
}

private enum KittenCamMode: Hashable {
    case viewing
    case control
}

private struct ModeSelectionView: View {
    @Binding var selectedMode: KittenCamMode?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.05, blue: 0.06),
                    Color(red: 0.10, green: 0.13, blue: 0.15),
                    Color(red: 0.02, green: 0.02, blue: 0.025)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("KittenCam")
                        .font(.largeTitle.weight(.bold))

                    Text("Choose how this device should join the local camera setup.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 14) {
                    modeButton(
                        title: "Viewing Device",
                        subtitle: "Use this iPhone as the camera and stream it on your network.",
                        symbol: "camera.fill",
                        accent: .green
                    ) {
                        selectedMode = .viewing
                    }

                    modeButton(
                        title: "Control Device",
                        subtitle: "Discover KittenCam cameras, watch feeds, record, and control settings.",
                        symbol: "rectangle.connected.to.line.below",
                        accent: .cyan
                    ) {
                        selectedMode = .control
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(24)
            .frame(maxWidth: 520)
        }
        .preferredColorScheme(.dark)
    }

    private func modeButton(
        title: String,
        subtitle: String,
        symbol: String,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 44, height: 44)
                    .background(accent.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(16)
            .background(.white.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}
