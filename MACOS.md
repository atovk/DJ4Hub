# DJ 4G Hub for macOS

This branch adds a native macOS service for supported DJI 4G modules / Quectel
EG25-G. It does not require UTM for AT-mode management.

## Current scope

- Automatic discovery of DJI (`2ca3`) and Quectel (`2c7c`) USB serial ports
- Modem, SIM, operator, registration and signal status
- Receive and send SMS through the modem AT port
- Execute explicit AT commands
- Read and switch physical eUICC profiles through AT APDU transport
- Local management page at `http://127.0.0.1:7575`
- Packaged Intel amd64 and Apple Silicon arm64 releases

The cellular data interface remains managed by macOS. This allows macOS to use
the dongle as its network connection while DJ 4G Hub uses a separate USB serial
interface for management.

## Downloaded release

DJ 4G Hub publishes two macOS artifact families for each `v*` tag:

- `DJ-4G-Hub-macOS-<arch>-<tag>.zip` is the portable command-line/Web service
  package. It contains the executable, its libusb runtime, licenses, installer
  and the `dj4ghub` terminal launcher.
- `DJ-4G-Hub-macOS-<arch>-App-<tag>.zip` contains the native SwiftUI
  `DJ 4G Hub.app`, with the matching backend bundled inside the app.

Use `arm64` for Apple Silicon Macs and `amd64` for Intel Macs. Both require
macOS 13 or newer. The artifacts are ad-hoc signed and not notarized. A package
being built for an architecture does not mean every hardware, call-audio,
sleep/wake or long-running scenario has been verified on that architecture.

Download artifacts from:

```text
https://github.com/atovk/DJ4Hub/releases
```

The portable ZIP does not require Go, Homebrew or a separately installed libusb
on the user's Mac.

From the extracted release directory:

```sh
./dj4ghub start
```

The terminal remains attached to the service and the management page opens
automatically. Press `Control+C` to stop it, or run `./dj4ghub stop` from another
terminal in the same directory. Logs are stored in
`~/Library/Logs/DJ 4G Hub/dj4ghub.log`.

## Build from source

Requirements:

- macOS 13 or newer
- Go 1.26 or newer
- Xcode Command Line Tools
- `pkg-config`, `curl` and `lipo`

The release package must be built on the same architecture as the target:

```sh
./scripts/package-macos.sh v0.1.0-preview arm64
./scripts/package-macos.sh v0.1.0-preview amd64
```

The architecture-specific wrapper scripts remain available:

```sh
./scripts/package-macos-arm64.sh v0.1.0-preview
./scripts/package-macos-amd64.sh v0.1.0-preview
```

Portable package outputs:

- `dist/release/DJ-4G-Hub-macOS-<arch>-v0.1.0-preview/`
- `dist/release/DJ-4G-Hub-macOS-<arch>-v0.1.0-preview.zip`
- `dist/release/DJ-4G-Hub-macOS-<arch>-v0.1.0-preview.zip.sha256`

Build the native app from an existing portable backend package:

```sh
./scripts/package-macos-app.sh \
  "$PWD/dist/release/DJ-4G-Hub-macOS-arm64-v0.1.0-preview" \
  "$PWD/dist/native/DJ 4G Hub.app"
```

Use the matching `amd64` backend directory on Intel Macs. The app packager
checks that the Swift binary, backend binary and bundled libusb all use the same
single architecture.

The packaging script downloads the official libusb source archive, verifies its
SHA-256, builds it for macOS 13 or newer and bundles the resulting runtime. The
DJ 4G Hub packaging flow does not require the 4G Connect submodule.

## CI and release flow

GitHub CI runs on both `macos-15-intel` and `macos-15`:

- shell syntax checks for packaging scripts
- `go vet ./...`
- `go test ./...`
- `go test -race ./...`
- `./scripts/build-macos.sh <arch>`
- `swift test --package-path apps/hub-macos`
- `node --test scripts/phone-audio.test.cjs`

Pushing a `v*` tag runs the release workflow on both architectures, repeats the
tests, builds the portable package with `./scripts/package-macos.sh <tag> <arch>`,
builds the native app ZIP from that backend package, writes SHA-256 files, and
uploads all artifacts to the GitHub Release.

## Run

Connect the modem and run:

```sh
./dist/dj4ghub-macos
```

If automatic discovery picks no AT port, inspect `/dev/cu.*` and pass it:

```sh
./dist/dj4ghub-macos -port /dev/cu.usbmodemXXXX
```

The server only listens on localhost by default. Open:

```text
http://127.0.0.1:7575
```

## Demo without hardware

To explore the management page before buying the module, run:

```sh
./dist/dj4ghub-macos -demo
```

Then open `http://127.0.0.1:7575`. Demo mode provides simulated modem status,
SMS messages, AT command responses and eSIM profiles. It does not access a real
SIM, send messages or switch a physical eSIM profile.

## One-shot network activation

To prepare the ECM network interface without starting the web service, stop any
running DJ 4G Hub service and run:

```sh
./dj4ghub activate
```

The command removes or disables only orphaned Baiwang/EG25/QDC507 network
services, ensures `usbnet=1`, reboots the module when the ECM interface is
unavailable, waits for macOS DHCP, and then exits.

## Logs

Logs are written to `~/Library/Logs/DJ 4G Hub/dj4ghub.log`.

## Platform limitations

- Native QMI/MBIM control, Linux udev and network-namespace orchestration are
  excluded from this macOS entry point.
- eSIM behavior depends on the physical eUICC and modem firmware. Profile
  switching must be verified with real hardware.
- The release uses an ad-hoc signature rather than an Apple Developer ID. On
  first run, macOS may require approval in Privacy & Security.
