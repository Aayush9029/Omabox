# Apple APIs

Omabox targets macOS 26 on Apple silicon. SwiftUI and AppKit provide the interface; Virtualization runs Linux.

- [`VZLinuxBootLoader`](https://developer.apple.com/documentation/virtualization/vzlinuxbootloader): kernel and initramfs boot.
- [`VZVirtualMachineView`](https://developer.apple.com/documentation/virtualization/vzvirtualmachineview): display and local input.
- [`Virtio graphics`](https://developer.apple.com/documentation/virtualization/vzvirtiographicsdeviceconfiguration): framebuffer without Linux GPU acceleration.
- [`Virtio filesystems`](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration): selected folders and read-only configuration.
- [`Virtio sockets`](https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice): clipboard and SSH control.
- [`Liquid Glass`](https://developer.apple.com/documentation/technologyoverviews/liquid-glass): native materials.

VM operations use the designated serial queue. A successful VM start does not mean the Linux desktop is ready.

App Sandbox limits file access to the container and selected folders. Microphone access requires authorization. Displaying the guest needs no Mac screen-recording permission; local input needs no global Accessibility permission.

macOS 27-only DiskImageKit and `VZVirtualMachineViewAdaptor` are outside the baseline.

[Apple's Linux guide](https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac) · [Validation](Validation.md)
