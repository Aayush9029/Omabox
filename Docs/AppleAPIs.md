# Apple APIs and Linux integration

Omabox targets Apple silicon and macOS 26 or later. It uses SwiftUI and AppKit for the host interface and Apple's Virtualization framework for the virtual hardware. A successful `VZVirtualMachine.start()` means the virtual machine started; it does not establish that Linux finished booting or that its desktop is ready.

## Baseline and availability

Apple's [GUI Linux sample](https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac) demonstrates a Linux VM with a native display, keyboard and pointing devices, audio, networking, and clipboard support. The [custom Linux guide](https://developer.apple.com/documentation/virtualization/creating-and-running-a-linux-virtual-machine) covers direct kernel and initial RAM disk boot. Apple silicon requires an ARM64 guest kernel and operating system. Rosetta translates selected x86_64 user-space Linux binaries; it does not boot an x86_64 operating system.

The implementation uses `VZLinuxBootLoader`, `VZGenericPlatformConfiguration`, `VZVirtioBlockDeviceConfiguration`, `VZVirtioGraphicsDeviceConfiguration`, `VZUSBKeyboardConfiguration`, `VZUSBScreenCoordinatePointingDeviceConfiguration`, `VZVirtioSoundDeviceConfiguration`, `VZVirtioNetworkDeviceConfiguration`, `VZVirtioFileSystemDeviceConfiguration`, and `VZVirtioSocketDeviceConfiguration`. These are available on macOS 26.

The macOS 27 SDK adds APIs that cannot be the macOS 26 baseline:

- `DiskImageKit` and `VZDiskImageStorageDeviceAttachment(diskImage:)` are macOS 27 APIs. The ASIF disk format itself arrived in macOS 26, where Apple documents creating it through `diskutil`. Omabox uses a raw sparse disk image for its baseline. See [disk storage attachments](https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment) and [DiskImageKit](https://developer.apple.com/documentation/diskimagekit).
- `VZVirtualMachineViewAdaptor` is macOS 27. Omabox keeps its VZ object graph on the main actor and the framework's main dispatch queue, with asynchronous lifecycle calls. Disk preparation runs separately. The `VZVirtualMachine.queue` property is available in macOS 26. The framework requires all other VM interactions on its designated serial queue.
- Custom Virtio device APIs and additional networking and accessory capabilities presented in [WWDC26's Virtualization session](https://developer.apple.com/videos/play/wwdc2026/224/) require their documented newer availability checks.

These boundaries were checked against the installed Xcode 27 Beta 6 framework headers and Swift module interface, rather than inferred from the current documentation landing page.

## Display and input

[`VZVirtualMachineView`](https://developer.apple.com/documentation/virtualization/vzvirtualmachineview) displays the guest framebuffer and forwards keyboard and pointer events through configured devices. `automaticallyReconfiguresDisplay` responds to window resizing. A single Virtio graphics scanout is supported by the public configuration.

The host menu's Resolution submenu offers fixed 512 × 320, 960 × 600, 1280 × 800, 1440 × 900, and 1920 × 1200 guest framebuffer sizes. Fixed presets disable automatic reconfiguration and pass the selected pixel dimensions to `VZGraphicsDisplay.reconfigure(sizeInPixels:)`; the dimensions are not multiplied by the Mac screen's Retina scale. Fit to screen restores automatic reconfiguration and fits the native window to the current screen's usable area. Guest display-service handling remains responsible for applying the updated mode inside Linux.

The public Linux Virtio graphics configuration exposes framebuffer scanouts and no Linux GPU acceleration or GPU passthrough configuration. The implementation therefore must not promise accelerated Linux 3D graphics or native GPU performance. Hyprland's software rendering compatibility and performance require validation in the actual guest; macOS guest graphics behavior is not evidence for Linux graphics capability. See [Virtio graphics configuration](https://developer.apple.com/documentation/virtualization/vzvirtiographicsdeviceconfiguration).

System shortcut capture is opt-in through `capturesSystemKeys`. **Control-Option-Command-K** (**⌃⌥⌘K**) opens the host menu while the VM is running or paused; plain **Command-K** is forwarded to the guest. The host also retains its Settings shortcut and provides **Control-Option-Escape** and the menu's **Release Keyboard** action to release input. Local VM keyboard interaction does not require global Accessibility or Input Monitoring access.

The runtime display fills the window and hides the native traffic lights. The only regular host control over the display is the **⌃⌥⌘K** text at the bottom left. It hides after five seconds of inactivity and reappears with pointer activity or window focus; accessibility focus and VoiceOver keep it visible. The host menu adapts to a 512 × 320 window. Pausing covers the display with a full material overlay, a pause symbol, and a **Resume** capsule; the host menu offers **Resume** in place of **Pause**.

## Sandbox and permissions

Creating a VM requires [`com.apple.security.virtualization`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization). The app retains App Sandbox and Hardened Runtime. File access is limited to the app container and folders explicitly selected by the user. Networking uses a `VZNATNetworkDeviceAttachment`; it does not use privileged bridge setup or an external hypervisor executable.

The microphone is initially disabled. Enabling it requests macOS authorization through AVFoundation; only an authorized subsequent VM start attaches a `VZHostAudioInputStreamSource`. The app needs a microphone usage description and the relevant [audio-input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input). The input source follows the host's default audio input. Output uses the host's default output device. Linux needs its Virtio sound driver and PipeWire or another compatible audio stack.

Showing a VM framebuffer does not capture the host desktop. Screen sharing within Linux uses the guest's PipeWire and desktop portal. A future feature that deliberately captures the Mac screen would separately need ScreenCaptureKit and its user authorization; no such host capture permission is requested by the current VM display.

## Clipboard, files, and guest services

Apple's [SPICE attachment](https://developer.apple.com/documentation/virtualization/vzspiceagentportattachment) supports clipboard sharing when the guest implements the SPICE agent. Installing `spice-vdagent` alone is not proof of functional Hyprland/Wayland clipboard integration. Omabox instead implements a small explicit text bridge over [Virtio sockets](https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice), backed by `wl-copy` and `wl-paste` in the graphical guest session.

The guest listens on vsock port 4040. It sends a newline-delimited JSON greeting with type `ready` and version `1`. Text frames contain type `clipboard` and a `text` string. Both sides cap text at 65,536 UTF-8 bytes and suppress duplicate values. The host caps buffered frames, rejects malformed or unknown messages, uses nonblocking I/O, and reconnects after guest restarts. Host pasteboard sharing occurs only while Omabox is active and the setting is enabled. Disabling sharing closes the connection immediately. Clipboard contents are never logged. This protocol conveys text only; it cannot issue host commands.

Folder sharing uses a security-scoped bookmark and [`VZSharedDirectory`](https://developer.apple.com/documentation/virtualization/vzshareddirectory), with read-only access as the default. The scope remains open for the active VM and closes when the VM stops. A stale or unavailable bookmark is an actionable startup failure. The Virtio filesystem tag is `omabox`; the guest mount configuration controls its mount point. The Linux kernel must include `CONFIG_VIRTIO_FS`. See [shared directories](https://developer.apple.com/documentation/virtualization/shared-directories).

Linux configuration uses a separate [`VZVirtioFileSystemDeviceConfiguration`](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration) tagged `omabox-config`. A single read-only `VZSharedDirectory` exposes the app-owned `Omabox/LinuxConfiguration` directory under Application Support, and the guest mounts it at `/mnt/omabox-config`. This share is independent of the selected Mac folder and the SSH folder. Missing `desktop.env` and `hyprland.lua` files are created empty; existing files are preserved. At the next Linux desktop start, explicit host environment and Lua settings apply after the corresponding guest settings without overwriting the guest's files.

The file actions open the selected local configuration file in TextEdit using [`NSWorkspace.open(_:withApplicationAt:configuration:completionHandler:)`](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:)). The native asynchronous API opens a URL in a specified Mac application; no shell command or custom editor is involved.

Optional SSH setup uses a separate host-only Virtio socket channel on port 4041. Sharing settings grants access to a selected Mac SSH folder and transfers only the selected public key. The guest waits for Linux's non-root first-owner account, then configures key-only SSH on port 2222. The Mac configuration uses a managed alias and a pinned guest host key while preserving unrelated SSH entries. Private key contents are neither read by the app nor transferred to the guest, and the SSH folder is never mounted through VirtioFS. Native settings, real SSH/SFTP, authentication rejection, and revocation were checked with disposable keys and a disposable guest. See [SSH setup and configuration ownership](SSH.md) and [validation evidence](Validation.md).

## Lifecycle and validation

Omabox distinguishes absent, preparing, ready, starting, running, paused, stopping, and failed states. Guest shutdown is requested gracefully. If it has not completed after 20 seconds, the interface offers continued waiting or a deliberate Force Stop; elapsed time never implies success. Pause keeps a session in host memory and is not a disk snapshot.

The runtime probes `validateSaveRestoreSupport()` and does not assume a Linux device configuration can be saved. Apple's save format is tied to its host, compatible configuration, and host software. External disks and other state must be preserved consistently; a memory save alone is not a portable backup. See [save and restore](https://developer.apple.com/videos/play/wwdc2023/10007/).

Unit tests cover invalid hardware limits, preparation and startup failure, lifecycle transitions, shutdown confirmation, microphone denial, clipboard revocation, and bounded clipboard parsing. Release validation still requires real ARM Linux boot, software graphics, audio playback and recording, guest portals, text sharing in both directions, folder writes and read-only enforcement, keyboard capture and release, window resizing, and reboot persistence on macOS 26 hardware.

## Native Mac controls

The interface uses SwiftUI and AppKit controls, matching the requested meaning of “Apple Control.” [Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/liquid-glass), [`glassEffect`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)), [`GlassEffectContainer`](https://developer.apple.com/documentation/swiftui/glasseffectcontainer), and [`NSGlassEffectView`](https://developer.apple.com/documentation/appkit/nsglasseffectview) provide the macOS 26 material. Settings use `NavigationSplitView`, grouped `Form` rows, and an active `NSVisualEffectView` behind the window. The native settings components use the original design resources with Linux configuration and service state.

Home uses a fixed 880 × 560-point window whose content fills the title-bar region. CPU and memory use preset blocks constrained by the Mac's resource limits, disk capacity appears as read-only text, and Linux Configuration Files has its own section with native TextEdit actions. The subtitle is “Run Omarchy in a virtual machine,” and the secondary Settings button in the welcome column opens General. Runtime window geometry is managed separately, so shrinking the guest does not shrink Home.
