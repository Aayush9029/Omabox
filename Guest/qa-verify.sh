#!/bin/bash
set -euo pipefail
[[ -d /home/omaboxqa && ! -f /var/lib/omarchy/provisioning/pending ]]
export SYSTEMD_COLORS=0 SYSTEMD_PAGER=cat TERM=dumb
mode=${1:-native}

for attempt in {1..30}; do
  pgrep -u omaboxqa Hyprland >/dev/null && pgrep -u omaboxqa quickshell >/dev/null && break
  sleep 1
done
instance=$(runuser -u omaboxqa -- env XDG_RUNTIME_DIR=/run/user/1000 hyprctl instances -j)
signature=$(printf '%s' "$instance" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["instance"])')
wayland=$(printf '%s' "$instance" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["wl_socket"])')
user_run() {
  runuser -u omaboxqa -- env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    WAYLAND_DISPLAY="$wayland" HYPRLAND_INSTANCE_SIGNATURE="$signature" "$@"
}
[[ -z $(user_run hyprctl configerrors) ]]
test -f /home/omaboxqa/.config/omabox/desktop.env
test -f /home/omaboxqa/.config/omabox/hyprland.lua
if [[ $mode == custom ]]; then
  expected_threads=1
  expected_scale=2
  sha256sum -c /home/omaboxqa/.omabox-qa-config.sha256
else
  expected_threads=2
  expected_scale=1
fi
tr '\0' '\n' <"/proc/$(pgrep -u omaboxqa -x Hyprland)/environ" | grep -Fx "LP_NUM_THREADS=$expected_threads"
user_run hyprctl monitors -j | python3 -c 'import json,sys; assert json.load(sys.stdin)[0]["scale"] == float(sys.argv[1])' "$expected_scale"
user_run systemctl --user is-active omabox-clipboard.service pipewire.service xdg-desktop-portal-hyprland.service
[[ $(findmnt -n -o FSTYPE /mnt/omabox) == virtiofs ]]
grep -q virtio-snd /proc/asound/pcm
host_token=omabox-host-clipboard-qa-20260911
for attempt in {1..30}; do
  [[ $(user_run wl-paste --no-newline --type text 2>/dev/null || true) == "$host_token" ]] && break
  sleep 1
done
[[ $(user_run wl-paste --no-newline --type text) == "$host_token" ]]
printf omabox-guest-clipboard-qa-20260911 | user_run wl-copy
mkdir -p /mnt/omabox-qa
mountpoint -q /mnt/omabox-qa || mount -t virtiofs omabox-qa /mnt/omabox-qa
user_run grim /home/omaboxqa/omabox-qa.png
cp /home/omaboxqa/omabox-qa.png "/mnt/omabox-qa/desktop-$mode.png"
user_run hyprctl monitors -j > /mnt/omabox-qa/monitors.json
user_run hyprctl systeminfo > /mnt/omabox-qa/systeminfo.txt
cat /proc/asound/cards > /mnt/omabox-qa/audio.txt
cat /proc/asound/pcm >> /mnt/omabox-qa/audio.txt
findmnt /mnt/omabox > /mnt/omabox-qa/shared-folder.txt
user_run systemctl --user --no-pager --failed > /mnt/omabox-qa/failed-user-units.txt
pgrep -a Hyprland
pgrep -a quickshell
user_run hyprctl systeminfo | grep -Ei 'renderer|llvmpipe|software|GPU' || true
if [[ $mode == native ]]; then
  printf 'LP_NUM_THREADS=1\nOMABOX_DISPLAY_SCALE=2\n' > /home/omaboxqa/.config/omabox/desktop.env
  printf 'hl.config({ decoration = { rounding = 13 }, animations = { enabled = false } })\n' > /home/omaboxqa/.config/omabox/hyprland.lua
  chown omaboxqa:omaboxqa /home/omaboxqa/.config/omabox/desktop.env /home/omaboxqa/.config/omabox/hyprland.lua
  sha256sum /home/omaboxqa/.config/omabox/desktop.env /home/omaboxqa/.config/omabox/hyprland.lua > /home/omaboxqa/.omabox-qa-config.sha256
fi
sleep 2
echo OMABOX_QA_VERIFIED
