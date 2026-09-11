# Guest factory

Run `../Scripts/prepare-guest.sh` from this directory, or `Scripts/prepare-guest.sh` from the repository root, on an Apple silicon Mac. The build downloads and verifies a pinned factory release, then adapts a separate disk using Apple's Virtualization framework. It requires about 15 GiB of free storage for the download, expanded template, and temporary build data.

`source.json` pins the input release. `overlay` contains Omabox's Wayland clipboard service, dynamic display service, shared-folder mount, and desktop defaults. `adapt-guest.sh` applies the overlay in the temporary guest and builds the matching Virtio sound module. `virtio-sound-source` contains its verified upstream source and license material.

The generated `Omabox/Resources/Guest` directory is an unprovisioned factory. The app copies it to private persistent storage and lets Omarchy collect the owner's account details at first boot. Developer bootstrap tools are not part of the shipped runtime.

Run `Scripts/check-guest.sh` from the repository root to verify an isolated copy. It starts a real graphical session, checks sound, folders, portals and clipboard exchange, exports a screenshot, and shuts down. The test-only account exists solely in that disposable copy.

Run `python3 Scripts/QA/check_reliability.py` for networking, shared-folder permissions and persistence, silent PCM playback, pause/resume, live display resizing, and idle CPU measurements. The native helper discards all guest audio. These checks use separate disposable copies.

Guest preferences live in `~/.config/omabox/desktop.env` and `~/.config/omabox/hyprland.lua`. For example, `LP_NUM_THREADS=2` changes software-rendering concurrency, and `OMABOX_DISPLAY_SCALE=2` requests twice the display scale on the next desktop start. Set `OMABOX_DYNAMIC_RESOLUTION=0` in `desktop.env` to preserve a manually configured guest resolution when the Mac window changes size. Remove that entry or set it to `1` to resume automatic sizing on the next display change. Preferences are literal assignments and never execute shell commands.

See [runtime documentation](../Docs/Virtualization.md) for architecture, limitations, provenance, and validation requirements.
