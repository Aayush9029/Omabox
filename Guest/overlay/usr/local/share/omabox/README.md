# Desktop preferences

Linux preferences live in `~/.config/omabox`. Existing files survive restarts; missing files are recreated from defaults.

`desktop.env` accepts literal `NAME=value` lines, without shell expansion or quote processing:

```text
LP_NUM_THREADS=2
OMABOX_DISPLAY_SCALE=1
GDK_SCALE=1
```

Environment values apply in this order: built-in defaults, app startup settings, Linux `desktop.env`, then the Mac's `desktop.env` from `/mnt/omabox-config`. Explicit Mac values override matching Linux values; an empty Mac file preserves them.

Hyprland applies the resulting display settings, then Linux `hyprland.lua`, then the Mac's `hyprland.lua`. The default Linux Lua file disables blur, shadows, and animations.

Restart Linux after environment changes; reload Hyprland after Lua changes. Remove an override to use the earlier value again. Omabox uses llvmpipe software rendering; changing environment variables cannot add a hardware GPU backend.
