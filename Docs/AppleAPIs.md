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

[`VZVirtualMachineView`](https://developer.apple.com/documentation/virtualization/vzvirtualmachineview) displays the guest framebuffer and forwards keyboard and pointer events through configured devices. `automaticallyReconfiguresDisplay` responds to window resizing. A single Virtio graphics scanout is supported by the public configuration. Omabox starts at 1440 × 900 and lets the guest respond to native display size changes.

The public Linux Virtio graphics configuration exposes framebuffer scanouts and no Linux GPU acceleration or GPU passthrough configuration. The implementation therefore must not promise accelerated Linux 3D graphics or native GPU performance. Hyprland's software rendering compatibility and performance require validation in the actual guest; macOS guest graphics behavior is not evidence for Linux graphics capability. See [Virtio graphics configuration](https://developer.apple.com/documentation/virtualization/vzvirtiographicsdeviceconfiguration).

System shortcut capture is opt-in through `capturesSystemKeys`. The host retains its command palette and Settings shortcuts and provides a release-input shortcut. Local VM keyboard interaction does not require global Accessibility or Input Monitoring access.

## Sandbox and permissions

Creating a VM requires [`com.apple.security.virtualization`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization). The app retains App Sandbox and Hardened Runtime. File access is limited to the app container and folders explicitly selected by the user. Networking uses a `VZNATNetworkDeviceAttachment`; it does not use privileged bridge setup or an external hypervisor executable.

The microphone is initially disabled. Enabling it requests macOS authorization through AVFoundation; only an authorized subsequent VM start attaches a `VZHostAudioInputStreamSource`. The app needs a microphone usage description and the relevant [audio-input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input). The input source follows the host's default audio input. Output uses the host's default output device. Linux needs its Virtio sound driver and PipeWire or another compatible audio stack.

Showing a VM framebuffer does not capture the host desktop. Screen sharing within Linux uses the guest's PipeWire and desktop portal. A future feature that deliberately captures the Mac screen would separately need ScreenCaptureKit and its user authorization; no such host capture permission is requested by the current VM display.

## Clipboard, files, and guest services

Apple's [SPICE attachment](https://developer.apple.com/documentation/virtualization/vzspiceagentportattachment) supports clipboard sharing when the guest implements the SPICE agent. Installing `spice-vdagent` alone is not proof of functional Hyprland/Wayland clipboard integration. Omabox instead implements a small explicit text bridge over [Virtio sockets](https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice), backed by `wl-copy` and `wl-paste` in the graphical guest session.

The guest listens on vsock port 4040. It sends a newline-delimited JSON greeting with type `ready` and version `1`. Text frames contain type `clipboard` and a `text` string. Both sides cap text at 65,536 UTF-8 bytes and suppress duplicate values. The host caps buffered frames, rejects malformed or unknown messages, uses nonblocking I/O, and reconnects after guest restarts. Host pasteboard sharing occurs only while Omabox is active and the setting is enabled. Disabling sharing closes the connection immediately. Clipboard contents are never logged. This protocol conveys text only; it cannot issue host commands.

Folder sharing uses a security-scoped bookmark and [`VZSharedDirectory`](https://developer.apple.com/documentation/virtualization/vzshareddirectory), with read-only access as the default. The scope remains open for the active VM and closes when the VM stops. A stale or unavailable bookmark is an actionable startup failure. The Virtio filesystem tag is `omabox`; the guest mount configuration controls its mount point. The Linux kernel must include `CONFIG_VIRTIO_FS`. See [shared directories](https://developer.apple.com/documentation/virtualization/shared-directories).

## Lifecycle and validation

Omabox distinguishes absent, preparing, ready, starting, running, paused, stopping, and failed states. Guest shutdown is requested gracefully. If it has not completed after 20 seconds, the interface offers continued waiting or a deliberate Force Stop; elapsed time never implies success. Pause keeps a session in host memory and is not a disk snapshot.

The runtime probes `validateSaveRestoreSupport()` and does not assume a Linux device configuration can be saved. Apple's save format is tied to its host, compatible configuration, and host software. External disks and other state must be preserved consistently; a memory save alone is not a portable backup. See [save and restore](https://developer.apple.com/videos/play/wwdc2023/10007/).

Unit tests cover invalid hardware limits, preparation and startup failure, lifecycle transitions, shutdown confirmation, microphone denial, clipboard revocation, and bounded clipboard parsing. Release validation still requires real ARM Linux boot, software graphics, audio playback and recording, guest portals, text sharing in both directions, folder writes and read-only enforcement, keyboard capture and release, window resizing, and reboot persistence on macOS 26 hardware.

## Native Mac controls

The interface uses SwiftUI and AppKit controls, matching the requested meaning of “Apple Control.” [Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/liquid-glass), [`glassEffect`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)), [`GlassEffectContainer`](https://developer.apple.com/documentation/swiftui/glasseffectcontainer), and [`NSGlassEffectView`](https://developer.apple.com/documentation/appkit/nsglasseffectview) provide the macOS 26 material. Flare’s settings use `NavigationSplitView`, grouped `Form` rows, and an active `NSVisualEffectView` behind the window. The native settings source and all original resources are copied into Omabox; Linux settings and service state replace Flare’s chat-specific bindings.
