# Guest factory

Run `../Scripts/prepare-guest.sh` from this directory, or `Scripts/prepare-guest.sh` from the repository root, on an Apple silicon Mac. The build downloads and verifies a pinned factory release, then adapts a separate disk using Apple's Virtualization framework. It requires about 15 GiB of free storage for the download, expanded template, and temporary build data.

`source.json` pins the input release. `overlay` contains Omabox's Wayland clipboard service, dynamic display service, shared-folder mount, and desktop defaults. `adapt-guest.sh` applies the overlay in the temporary guest and builds the matching Virtio sound module. `virtio-sound-source` contains its verified upstream source and license material.

The generated `Omabox/Resources/Guest` directory is an unprovisioned factory. The app copies it to private persistent storage and lets Omarchy collect the owner's account details at first boot. Developer bootstrap tools are not part of the shipped runtime.

Run `Scripts/check-guest.sh` from the repository root to verify an isolated copy. It starts a real graphical session, checks sound, folders, portals and clipboard exchange, exports a screenshot, and shuts down. The test-only account exists solely in that disposable copy.

Run `python3 Scripts/QA/check_reliability.py` for networking, shared-folder permissions and persistence, silent PCM playback, pause/resume, live display resizing, and idle CPU measurements. The native helper discards all guest audio. These checks use separate disposable copies.

Guest preferences live in `~/.config/omabox/desktop.env` and `~/.config/omabox/hyprland.lua`. For example, `LP_NUM_THREADS=2` changes software-rendering concurrency, and a numeric `OMABOX_DISPLAY_SCALE=2` requests a fixed 2× display scale on the next desktop start. Environment preferences are literal assignments and never execute shell commands.

## Display scaling

Automatic scale adjusts the Linux compositor when the framebuffer resolution changes. It aims for a workspace near 1280 × 800 logical pixels, selecting a scale from 0.5× to 4×. The target moves in quarter steps, then uses the nearest fraction supported by Hyprland. The standard resolution presets produce these scales:

| Framebuffer pixels | Automatic scale |
| --- | --- |
| 512 × 320 | 0.5× |
| 960 × 600 | 0.75× |
| 1280 × 800 | 1× |
| 1440 × 900 | 1.25× |
| 1920 × 1200 | 1.5× |

The display service reacts to DRM resolution events and uses the actual preferred framebuffer dimensions. Fit to screen can produce a slightly rounded Linux framebuffer; for example, a 1500 × 940 request can become 1496 × 940. The selected Automatic scale follows that actual size.

A numeric `OMABOX_DISPLAY_SCALE` or an explicit numeric scale in a matching Lua monitor rule is preserved. Hyprland may adjust an incompatible scale so both framebuffer dimensions produce whole logical pixels. Custom mode, rotation, and mirroring rules are treated as manual configuration. Normal monitor-rule changes made through Lua are observed during the session. After switching a rule to `scale = 'auto'` through live Lua evaluation, reload the configuration or restart Linux. The reload restores the appropriate Automatic scale without another framebuffer change and preserves explicit manual rules. Environment files and startup Lua are loaded when the Linux desktop starts. Automatic scaling does not rewrite saved preferences.

Set `OMABOX_DYNAMIC_RESOLUTION=0` in `desktop.env` to disable the display synchronizer and keep a manually configured guest resolution. Remove that entry or set it to `1` to resume automatic sizing on the next display change. To return to Automatic scale, select Automatic in the Mac app, remove explicit scale or monitor overrides, and restart Linux.

See [runtime documentation](../Docs/Virtualization.md) for architecture, limitations, provenance, and validation requirements.

Omabox SSH access is optional and requires a prepared guest with integration version 2. A root service listens only for the Mac host on Virtio socket port 4041. The Mac sends one versioned JSON request per connection, limited to 16 KiB, to install one public key or disable access. SSH remains off until the Mac explicitly enables it after each Linux boot or integration service restart.

First-owner provisioning records the exact account name and UID in a root-owned marker. Setup requests made earlier remain pending. The dedicated OpenSSH service binds port 2222 on the Virtio network interface, accepts only public-key authentication for that owner, and stores its managed authorized keys separately from the owner's `~/.ssh`. It does not enable root or password login. Its dedicated service does not use PAM sessions, so disabling access or replacing the key can terminate its connections without terminating the owner's desktop session. Its private host key is generated in Linux on first enable and stays inside the guest.

Run `python3 -B -m unittest discover -s Guest -p 'test_ssh*.py'` for protocol and owner-marker checks. `python3 Scripts/QA/check_ssh.py` uses a disposable guest and new test keys to verify actual host-to-guest login, denial, revocation, and reboot behavior. Existing prepared disks keep their data and do not acquire this integration automatically.

To update an existing disk's Omabox integration, share a folder containing this repository with Linux, then run the updater from the Linux terminal:

```sh
sudo bash /mnt/omabox/Guest/install-integration.sh
```

Adjust the path if the repository is nested inside the shared folder. This updates only Omabox's integration files and services. It preserves the Linux account, disk contents, and preference files, and leaves SSH off until enabled from the Mac app. For a completed first-owner setup, the updater requires its recorded owner or original root-owned autologin configuration to identify the account; it stops with an error if that identity is unavailable. Finish first-owner setup before connecting. Shut Linux down and start it from the updated Mac app after the update.

The Mac app's Linux Configuration Files are shared separately from the optional user folder, through the read-only `omabox-config` mount at `/mnt/omabox-config`. Guest startup loads the Mac's `desktop.env` after the guest's environment preferences and its `hyprland.lua` after the guest's Lua preferences. New or empty Mac files receive a short instruction line that changes no settings. Files containing only that starter line preserve the guest defaults. Environment values are literal assignments, and a malformed host Lua file is ignored so it cannot prevent desktop startup. Existing guest preference files are preserved. The host environment's last valid `OMABOX_DYNAMIC_RESOLUTION=0` or `1` also takes precedence over the guest setting.

The combined updater above adds the configuration mount and display behavior to existing desktops. Starting Linux from the updated Mac app attaches the read-only configuration share.

`python3 Scripts/QA/check_configuration.py` verifies configuration through a dedicated read-only share across cold boots, including empty defaults, explicit host overrides, malformed Lua, literal environment values, and guest file preservation.
