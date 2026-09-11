<p align="center">
  <img src="Omabox/Resources/OmarchyMark.png" width="96" alt="Omarchy icon">
</p>

<h1 align="center">Omabox</h1>

<p align="center">A native Mac app for Omarchy.</p>

<p align="center">
  <a href="#build">
    <img alt="Build for Apple Silicon" src="https://img.shields.io/badge/Build%20for%20Apple%20Silicon-black.svg?style=for-the-badge&logo=apple">
  </a>
</p>

<p align="center">
  <img src="Docs/images/home.png" width="1100" alt="Omabox home showing the Omarchy desktop preview and configurable machine, sharing, and keyboard settings">
</p>

## Why Omabox

Run one persistent Omarchy desktop with Apple's Virtualization framework, native Mac controls, and the glass interface from [Flare](https://github.com/Aayush9029/Flare). Set CPU, memory, and storage before the first launch. Clipboard sharing, a shared folder, microphone access, keyboard capture, and display preferences are available from the home page and Settings.

Press **⌘K** while Omarchy is running to search commands and settings, or **⌘,** to open Settings at any time. Use **⌃⌥Esc** to release the keyboard. The Linux display follows your window size, and your files and desktop preferences stay in a private disk between launches.

<p align="center">
  <img src="Docs/images/settings.png" width="1100" alt="Omabox Settings with native controls and Flare's translucent sidebar and artwork">
</p>

## Build

Requires an Apple silicon Mac running **macOS 26 or later**, Xcode, and Tuist. Omabox is currently available as source; a notarized download has not been published.

```sh
git clone https://github.com/Aayush9029/Omabox.git
cd Omabox
./Scripts/prepare-guest.sh
./Scripts/build.sh
open build/DerivedData/Build/Products/Debug/Omabox.app
```

Guest preparation downloads and verifies a pinned Try Omarchy ARM image, then adapts a separate copy for Omabox. Allow at least 15 GiB of free space for preparation. Select **Set Up Omarchy** in the app and finish Linux's first-owner setup. No personal account is included in the template.

The app uses App Sandbox and Hardened Runtime. Folder access is limited to your selection, microphone access is optional, and clipboard sharing currently supports text. Linux graphics use software rendering; GPU acceleration is not available through Apple's public Linux virtualization API. The guest is an ARM adaptation of Omarchy, not an official Omarchy installation image.

See [build instructions and controls](Docs/Build.md), [validation results](Docs/Validation.md), [guest preparation](Guest/README.md), and [artwork provenance](Omabox/Resources/AssetProvenance.md).

Omabox's original code is available under the [MIT license](LICENSE). Guest software and third-party artwork retain their respective licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
