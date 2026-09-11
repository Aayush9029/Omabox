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

Public distribution also requires notarization. The source minimum remains macOS 26 when built with a newer Xcode SDK. See [archive and release instructions](Release.md) for distribution and [validation results](Validation.md) for the tested toolchain and current coverage.

## Set up your desktop

The home page uses a fixed 880 × 560-point split layout with editable configuration and the subtitle “Run Omarchy in a virtual machine.” Select **Set Up Omarchy** to create a private sparse disk from the bundled template, then finish Linux's first-owner setup. Future launches offer **Start Omarchy**. The full-width secondary **Settings** button in the welcome column opens General settings. The template contains no preconfigured personal account. Your desktop stays in the app's sandbox container when the application is closed or replaced.

Choose CPU and memory from the preset blocks on Home. Available choices follow the Mac's supported resource limits, and hardware changes apply after shutdown. The Home disk row displays capacity as read-only text. Machine settings allows initial disk capacity to be configured before installation; capacity is fixed afterward. Home also controls clipboard, microphone, shared folders, keyboard capture, display scale, and rendering threads.

## Linux configuration files

The separate **Linux Configuration Files** section opens **Environment** (`desktop.env`) and **Desktop** (`hyprland.lua`) in the Mac's TextEdit app. Omabox creates missing files as empty text files in `Omabox/LinuxConfiguration` inside its Application Support directory and preserves existing contents. Save changes in TextEdit, then restart the Linux desktop to apply them.

The files are exposed to Linux read-only at `/mnt/omabox-config`, separately from the selected shared Mac folder. Values added to the Mac's `desktop.env` override matching values in the guest's existing environment configuration. The Mac's `hyprland.lua` runs after the guest's existing Lua configuration. Empty files leave those guest preferences unchanged; they do not replace the files in `~/.config/omabox`.

Keep `desktop.env` as plain-text `KEY=VALUE` entries. For example, `LP_NUM_THREADS=2` selects two software-rendering threads, and `OMABOX_DYNAMIC_RESOLUTION=0` preserves a manually configured resolution when the Mac window changes size. The environment parser does not execute shell commands. See [guest configuration](../Guest/README.md) for supported values and the integration update procedure for existing desktops.

## Controls and integration

- **Control-Option-Command-K** (**⌃⌥⌘K**) opens the host menu while the desktop is running or paused. Plain **Command-K** passes through to Linux. **Command-comma** opens Settings at any time.
- The host menu includes Settings, **Resolution**, power controls, and **Release Keyboard**. **Resume** replaces **Pause** while the desktop is paused.
- Keyboard capture is optional. **Control-Option-Escape** releases input; clicking the desktop restores the selected capture behavior.
- Pause retains the running session in memory. Shutdown asks Linux to stop safely; Force Stop is an explicit fallback.
- Text clipboard sharing uses a bounded Wayland-aware service over Virtio sockets. Images and clipboard file transfers are not implemented.
- A selected Mac folder is available at `/mnt/omabox`. Read-only sharing is the default. Only the selected security-scoped folder is exposed.
- Microphone access is optional and requires the Mac permission prompt. Linux applications also control their own recording permissions.
- Linux screen sharing uses PipeWire and the guest desktop portal. Displaying the VM does not require access to the Mac screen.

The running desktop fills the window, with the native traffic lights hidden. Its only regular host control is the **⌃⌥⌘K** text at the bottom left, which opens the host menu and hides after five seconds of inactivity. Pointer activity or returning focus to the window reveals it again. Accessibility focus and VoiceOver keep it visible. While paused, a material overlay covers the desktop with a pause symbol and a **Resume** capsule.

Choose **Resolution** in the host menu to select **512 × 320**, **960 × 600**, **1280 × 800**, **1440 × 900**, or **1920 × 1200**. These values specify actual guest framebuffer pixels, independently of the Mac display's Retina scale. A fixed preset retains that guest resolution when the Mac window changes size. **Fit to screen** fits the window to the current screen's usable area and restores automatic guest display resizing. The host menu adapts to the 512 × 320 size.

## Optional SSH access

**Settings → Sharing → SSH Access** lets you choose an **SSH Folder** and select a **Public Key**. Only the public key is installed for Linux's non-root first-owner account; private key contents stay on the Mac. Setup waits until that owner account exists. The native settings flow, SSH login, SFTP, and access revocation have passed checks using disposable keys and a disposable guest; see [validation results](Validation.md).

The integration uses a host-only Virtio socket channel on port 4041 to configure a key-only guest SSH service on port 2222. It manages a Mac SSH alias and pins the guest host key while preserving unrelated SSH configuration. The selected SSH folder is not shared with Linux. See [SSH setup and existing-desktop updates](SSH.md) and [the testing guide](Testing.md).

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
