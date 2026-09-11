# Guest runtime

Omabox runs one ARM64 Linux desktop through Apple's Virtualization framework, with App Sandbox and Hardened Runtime enabled.

Virtio devices provide graphics, storage, NAT networking, audio, sockets, and folder sharing. Linux graphics use Mesa llvmpipe software rendering; guest GPU acceleration is unavailable.

The factory is a pinned Try Omarchy ARM adaptation, not an official Omarchy ARM image. Installation verifies it and creates a private disk. First boot creates your account; the factory has no personal account or shared password.

App updates preserve the installed disk and matching boot files. Never replace an existing disk with a newer factory. Pause retains memory; it is not a snapshot. Shut Down stops Linux gracefully, with explicit Force Stop as a fallback.

Disk growth after installation, snapshots, camera passthrough, and Mac screen capture are not implemented.

[Guest configuration](../Guest/README.md) · [Apple APIs](AppleAPIs.md) · [Validation](Validation.md) · [Licenses](../THIRD_PARTY_NOTICES.md)
