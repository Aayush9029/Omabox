#!/bin/bash
set -euo pipefail

[[ $(id -u) == 0 && $(uname -m) == aarch64 ]]
[[ -f /var/lib/omarchy/provisioning/pending ]]
[[ $(cat /etc/hostname) == omarchy-factory ]]

source_root=${1:-/mnt/build}
cp -a "$source_root/overlay/." /
chown -R root:root /usr/local/share/omabox /usr/local/libexec/omabox-clipboard-agent.py /usr/local/libexec/omabox-display-sync.py
chmod 0755 /usr/local/bin/omabox-start-desktop /usr/local/libexec/omabox-clipboard-agent.py /usr/local/libexec/omabox-display-sync.py

sed -i 's|^Exec=/usr/bin/start-hyprland.*|Exec=/usr/local/bin/omabox-start-desktop|' /usr/share/wayland-sessions/hyprland.desktop
for unit in omarchy-native-mac-share.service omarchy-native-clipboard-bridge.service omarchy-native-camera-bridge.service; do
  systemctl --root=/ disable "$unit" 2>/dev/null || true
  systemctl --root=/ --global disable "$unit" 2>/dev/null || true
done
systemctl --root=/ enable mnt-omabox.mount
systemctl --root=/ --global enable omabox-clipboard.service
systemctl --root=/ --global enable omabox-display-sync.service
mkdir -p /mnt/omabox

if [[ -d $source_root/virtio-sound-source ]]; then
  cp -a "$source_root/virtio-sound-source" /tmp/omabox-virtio-sound
  GCC_EXEC_PREFIX=/usr/lib/gcc/ make -C "/lib/modules/$(uname -r)/build" M=/tmp/omabox-virtio-sound CONFIG_SND_VIRTIO=m modules
  install -D -m 0644 /tmp/omabox-virtio-sound/virtio_snd.ko "/lib/modules/$(uname -r)/extra/virtio_snd.ko"
  depmod -a
  modinfo virtio_snd
  rm -rf /tmp/omabox-virtio-sound
fi

modinfo virtiofs >/dev/null
modinfo vmw_vsock_virtio_transport >/dev/null
modinfo virtio_snd >/dev/null
test -x /usr/bin/wl-paste
test -x /usr/bin/wl-copy
test -x /usr/bin/python3
test -x /usr/bin/udevadm
python3 -c 'import ctypes, ctypes.util; ctypes.CDLL(ctypes.util.find_library("drm") or "libdrm.so.2")'
test -f /var/lib/omarchy/provisioning/pending
printf 'omabox\n' > /etc/hostname
printf '1\n' > /usr/local/share/omabox/image-version
sync
echo OMABOX_ADAPTATION_COMPLETE
