# Build and use Omabox

Omabox runs one persistent ARM64 Linux desktop with Apple's Virtualization framework. The host app uses Swift 6, SwiftUI, AppKit, and Observation. It requires an Apple silicon Mac running macOS 26 or later. App Sandbox and Hardened Runtime are enabled for the app target.

## Build and open

Install Xcode with the macOS 26 SDK or later and Tuist, then run from the repository root:

```sh
./Scripts/prepare-guest.sh
./Scripts/build.sh
open build/DerivedData/Build/Products/Debug/Omabox.app
```

Guest preparation downloads the pinned Try Omarchy release, verifies its published SHA-256, extracts its unprovisioned ARM Linux factory, and adapts a private copy through a native Apple VM. It does not access an existing Try Omarchy desktop. Preparation needs about 15 GiB of free storage for the download, expanded template, and temporary build data. The prepared template is approximately 6 GiB logically and is excluded from source control.

The build script installs Swift package dependencies and generates the Xcode workspace through Tuist. It uses ad-hoc signing by default for local development. To build with a signing identity available in your keychain:

```sh
OMABOX_CONFIGURATION=Release \
OMABOX_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
./Scripts/build.sh
```

Public distribution also requires notarization. The source minimum remains macOS 26 when built with a newer Xcode SDK. See [validation results](Validation.md) for the tested toolchain and current coverage.

## Set up your desktop

The home page follows Helm's split splash layout, with Omarchy's mark, a screenshot from the native guest, and editable configuration. Select **Set Up Omarchy** to create a private sparse disk from the bundled template, then finish Linux's first-owner setup. Future launches offer **Start Omarchy**. The template contains no preconfigured personal account. Your desktop stays in the app's sandbox container when the application is closed or replaced.

CPU, memory, and initial disk capacity are configurable. Hardware changes apply after shutdown. Disk capacity is fixed after installation. The home page also controls clipboard, microphone, shared folders, keyboard capture, display scale, and rendering threads.

Guest overrides in `~/.config/omabox/desktop.env` and `~/.config/omabox/hyprland.lua` persist across restarts. Set `OMABOX_DYNAMIC_RESOLUTION=0` in `desktop.env` to preserve a manually configured resolution when the Mac window changes size. See [guest configuration](../Guest/README.md) for the supported values and precedence.

## Controls and integration

- **Command-K** searches actions and settings while the desktop is running. **Command-comma** opens Settings at any time.
- Keyboard capture is optional. **Control-Option-Escape** releases input; clicking the desktop restores the selected capture behavior.
- Pause retains the running session in memory. Shutdown asks Linux to stop safely; Force Stop is an explicit fallback.
- Text clipboard sharing uses a bounded Wayland-aware service over Virtio sockets. Images and clipboard file transfers are not implemented.
- A selected Mac folder is available at `/mnt/omabox`. Read-only sharing is the default. Only the selected security-scoped folder is exposed.
- Microphone access is optional and requires the Mac permission prompt. Linux applications also control their own recording permissions.
- Linux screen sharing uses PipeWire and the guest desktop portal. Displaying the VM does not require access to the Mac screen.

## Graphics and guest compatibility

Apple's public Linux Virtio graphics API presents a framebuffer without a guest 3D acceleration interface. Omabox configures a software-rendered Hyprland session. CPU virtualization runs natively on ARM, but Linux applications do not receive GPU acceleration. Resource usage, video playback, and desktop effects depend on software rendering.

The guest is built from a pinned Try Omarchy ARM adaptation of upstream Omarchy, with an Omabox overlay for Virtio sound, folders, software rendering, display resizing, and clipboard transport. It is not an official Omarchy ARM installation image. See [guest provenance and preparation](../Guest/README.md).

Omabox keeps the installed disk and its matching kernel/initramfs together. Updating the host app does not silently replace a user's Linux desktop. Disk growth after installation, VM libraries, disk snapshots, camera passthrough, and host-screen capture are outside the current interface.

## Verify

After preparing the guest and generating the workspace:

```sh
xcodebuild test \
  -workspace Omabox.xcworkspace \
  -scheme Omabox \
  -destination 'platform=macOS,arch=arm64'
```

The suite covers installation integrity, disk preservation, VM lifecycle errors, resource limits, clipboard framing, exclusive disk ownership, input focus, command search, settings, and native UI behavior. Debug UI testing isolates preferences and disables real guest installation and login-item changes.

See [Apple API research](AppleAPIs.md), [validation results](Validation.md), [test scenarios](Testing.md), and [resource provenance](../Omabox/Resources/AssetProvenance.md).
