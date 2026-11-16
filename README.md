# KittenCam (iOS)

KittenCam is an iOS app that exposes camera controls and status over a lightweight HTTP service running on a TCP listener. It’s intended as a reference for building an Android app with the same functionality.

## Quick Start
- Open the project in Xcode.
- Select a real device (camera/microphone required), build & run.
- Grant camera and microphone permissions when prompted.
- The app will start a TCP listener and advertise via Bonjour as `_kittencam._tcp` using the device name.

## Networking
- The app hosts a TCP server using Network.framework with simple HTTP parsing.
- The service is advertised on the local network via Bonjour (mDNS) with type `_kittencam._tcp`.
- The server chooses an available port dynamically and reports it in the UI.

## API

### GET /status
Returns the current camera status as JSON:
