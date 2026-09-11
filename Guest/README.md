# Guest factory

Run `../Scripts/prepare-guest.sh` from this directory, or `Scripts/prepare-guest.sh` from the repository root, on an Apple silicon Mac. The build downloads and verifies a pinned factory release, then adapts a separate disk using Apple's Virtualization framework. It requires about 15 GiB of free storage for the download, expanded template, and temporary build data.

`source.json` pins the input release. `overlay` contains Omabox's Wayland clipboard service, dynamic display service, shared-folder mount, and desktop defaults. `adapt-guest.sh` applies the overlay in the temporary guest and builds the matching Virtio sound module. `virtio-sound-source` contains its verified upstream source and license material.

The generated `Omabox/Resources/Guest` directory is an unprovisioned factory. The app copies it to private persistent storage and lets Omarchy collect the owner's account details at first boot. Developer bootstrap tools are not part of the shipped runtime.

Run `Scripts/check-guest.sh` from the repository root to verify an isolated copy. It starts a real graphical session, checks sound, folders, portals and clipboard exchange, exports a screenshot, and shuts down. The test-only account exists solely in that disposable copy.

Run `python3 Scripts/QA/check_reliability.py` for networking, shared-folder permissions and persistence, silent PCM playback, pause/resume, live display resizing, and idle CPU measurements. The native helper discards all guest audio. These checks use separate disposable copies.

Guest preferences live in `~/.config/omabox/desktop.env` and `~/.config/omabox/hyprland.lua`. For example, `LP_NUM_THREADS=2` changes software-rendering concurrency, and `OMABOX_DISPLAY_SCALE=2` requests twice the display scale on the next desktop start. Set `OMABOX_DYNAMIC_RESOLUTION=0` in `desktop.env` to preserve a manually configured guest resolution when the Mac window changes size. Remove that entry or set it to `1` to resume automatic sizing on the next display change. Preferences are literal assignments and never execute shell commands.

See [runtime documentation](../Docs/Virtualization.md) for architecture, limitations, provenance, and validation requirements.

Omabox SSH access is optional and requires a prepared guest with integration version 2. A root service listens only for the Mac host on Virtio socket port 4041. The Mac sends one versioned JSON request per connection, limited to 16 KiB, to install one public key or disable access. SSH remains off until the Mac explicitly enables it after each Linux boot or integration service restart.

First-owner provisioning records the exact account name and UID in a root-owned marker. Setup requests made earlier remain pending. The dedicated OpenSSH service binds port 2222 on the Virtio network interface, accepts only public-key authentication for that owner, and stores its managed authorized keys separately from the owner's `~/.ssh`. It does not enable root or password login. Its dedicated service does not use PAM sessions, so disabling access or replacing the key can terminate its connections without terminating the owner's desktop session. Its private host key is generated in Linux on first enable and stays inside the guest.

Run `python3 -B -m unittest discover -s Guest -p 'test_ssh*.py'` for protocol and owner-marker checks. `python3 Scripts/QA/check_ssh.py` uses a disposable guest and new test keys to verify actual host-to-guest login, denial, revocation, and reboot behavior. Existing prepared disks keep their data and do not acquire this integration automatically.

To add SSH integration to an existing disk, share a folder containing this repository with Linux, then run the updater from the Linux terminal:

```sh
sudo bash /mnt/omabox/Guest/install-ssh-integration.sh
```

Adjust the path if the repository is nested inside the shared folder. This updates only Omabox's integration files and services. It preserves the Linux account and disk contents, and leaves SSH off until enabled from the Mac app. For a completed first-owner setup, the updater requires its original root-owned autologin configuration to identify the account; it stops with an error if that identity is unavailable. Finish first-owner setup before connecting. After the update, use the Mac SSH setting again.

The Mac app's Linux Configuration Files are shared separately from the optional user folder, through the read-only `omabox-config` mount at `/mnt/omabox-config`. Integration version 3 loads `desktop.env` after the guest's environment preferences and loads `hyprland.lua` after the guest's Lua preferences. Empty host files preserve the guest defaults. Environment values are literal assignments, and a malformed host Lua file is ignored so it cannot prevent desktop startup. Existing guest preference files are preserved. The host environment's last valid `OMABOX_DYNAMIC_RESOLUTION=0` or `1` also takes precedence over the guest setting.

For an existing Linux disk, finish first-owner setup, share the repository folder, then run `sudo bash /mnt/omabox/Guest/install-integration.sh` inside Linux. This installs only Omabox's services and startup integration. Shut down Linux and start it from the updated Mac app to attach the configuration share. It does not replace the disk or the guest's preference files.

`python3 Scripts/QA/check_configuration.py` verifies configuration through a dedicated read-only share across cold boots, including empty defaults, explicit host overrides, malformed Lua, literal environment values, and guest file preservation.
