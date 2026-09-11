# Guest configuration

The guest is a pinned Try Omarchy ARM adaptation. [Build instructions](../Docs/Build.md) cover preparation; [source.json](source.json) and [prepared-release.json](prepared-release.json) pin its inputs.

Open **Environment** or **Desktop** from the Mac app to edit configuration in TextEdit. Save and restart Linux. These read-only shared files override matching guest settings without replacing `~/.config/omabox` preferences.

Environment entries are literal `NAME=value` lines. Useful settings:

- `LP_NUM_THREADS=2`: software-rendering threads.
- `OMABOX_DISPLAY_SCALE=2`: fixed scale.
- `OMABOX_DYNAMIC_RESOLUTION=0`: disable automatic resizing.

Automatic scale adapts to guest resolution. Explicit monitor rules take priority. To restore Automatic, select it in the app, remove overrides, and restart Linux. Live Lua changes to Automatic require a configuration reload.

For an older desktop, finish first-owner setup and share this repository. Run **inside Linux**, adjusting the path if needed:

```sh
sudo bash /mnt/omabox/Guest/install-integration.sh
```

Shut down and restart from the updated app. The updater preserves your account, disk, and preferences; SSH needs authorization again.

[SSH](../Docs/SSH.md) · [QA](../Scripts/QA/README.md)
