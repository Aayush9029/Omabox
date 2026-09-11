local requested = os.getenv("OMABOX_DISPLAY_SCALE") or "auto"
local scale = requested == "auto" and "auto" or tonumber(requested)
if scale == nil or (type(scale) == "number" and scale <= 0) then
  scale = "auto"
end
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = scale })
local gdk_scale = os.getenv("OMABOX_GDK_SCALE")
if gdk_scale then
  hl.env("GDK_SCALE", gdk_scale)
elseif type(scale) == "number" then
  hl.env("GDK_SCALE", tostring(math.max(1, math.floor(scale))))
end
local preferences = os.getenv("OMABOX_GUEST_PREFERENCES") or (os.getenv("HOME") .. "/.config/omabox")
dofile(preferences .. "/hyprland.lua")

pcall(dofile, "/mnt/omabox-config/hyprland.lua")
