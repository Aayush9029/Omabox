# Build and use Omabox

Requires Apple silicon, macOS 26+, Xcode with the macOS 26 SDK or later, and Tuist.

From the repository root:

```sh
./Scripts/prepare-guest.sh
./Scripts/build.sh
open build/DerivedData/Build/Products/Debug/Omabox.app
```

Allow about 15 GiB for guest preparation. In a clean checkout, `python3 Scripts/fetch-release-guest.py` can instead import the pinned guest from a published release.

Choose **Set Up Omarchy**, complete Linux setup, then use **Start Omarchy**. The home screen holds only the mark and that one button. Every setting lives in Settings and in the ⌘K palette. CPU and memory changes apply after shutdown; disk capacity is fixed after installation. App updates preserve your desktop.

- **⌘K** opens the commands palette on the home screen and over the desktop. When Linux holds your system shortcuts and the keyboard, ⌘K goes to Linux and **⌃⌥⌘K** opens the palette instead.
- **⌘,** opens Settings; **⌃⌥Escape** releases input.
- **Resolution** selects guest pixels; **Fit to screen** restores automatic resizing.

Clipboard sharing supports text. Folder sharing defaults to read-only, and microphone access requires permission. Linux graphics use software rendering.

[Configuration](../Guest/README.md) · [SSH](SSH.md) · [Testing](Testing.md) · [Releases](Release.md)
