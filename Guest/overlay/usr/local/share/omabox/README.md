# Your desktop preferences

Omabox keeps your custom settings in `~/.config/omabox` inside Linux. These files are created the first time your desktop starts and are preserved across later starts and host setting changes.

`desktop.env` accepts literal `KEY=VALUE` lines. Leave it empty to follow the app's settings. Values are not shell commands and do not expand variables or quotes. Examples:

```text
LP_NUM_THREADS=2
OMABOX_DISPLAY_SCALE=1
GDK_SCALE=1
```

`hyprland.lua` holds your compositor preferences. It initially disables blur, shadows, and animations to reduce CPU rendering work. Edit those values freely, or add your own Hyprland configuration. This file runs after Omabox applies the host's display setting, so your explicit Lua settings take precedence.

Each start applies the built-in defaults, then the host's current display and render-thread preferences, then your `desktop.env`, then your `hyprland.lua`. Removing a custom setting lets the host's setting apply again. Removing either file recreates its original defaults on the next desktop start.

Apple Virtualization provides a Linux framebuffer without a hardware 3D graphics backend. Omabox therefore selects Mesa llvmpipe software rendering by default. You can experiment with `LIBGL_ALWAYS_SOFTWARE` and `GALLIUM_DRIVER` in `desktop.env`, but changing these variables does not add a GPU backend that the virtual machine does not have.
