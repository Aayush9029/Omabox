#!/bin/bash
set -euo pipefail

source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for source in usr/local/libexec/omabox-desktop-environment.sh usr/local/libexec/omabox-display-sync.py usr/local/bin/omabox-start-desktop usr/local/share/omabox/runtime.lua usr/local/share/omabox/display-policy.lua 'etc/systemd/system/mnt-omabox\x2dconfig.mount'; do
  test -f "$source_root/overlay/$source"
done
bash "$source_root/install-ssh-integration.sh"
for source in usr/local/libexec/omabox-desktop-environment.sh usr/local/libexec/omabox-display-sync.py usr/local/bin/omabox-start-desktop; do
  install -D -o root -g root -m 0755 "$source_root/overlay/$source" "/$source"
done
install -D -o root -g root -m 0644 "$source_root/overlay/usr/local/share/omabox/runtime.lua" /usr/local/share/omabox/runtime.lua
install -D -o root -g root -m 0644 "$source_root/overlay/usr/local/share/omabox/display-policy.lua" /usr/local/share/omabox/display-policy.lua
mount_unit='mnt-omabox\x2dconfig.mount'
install -D -o root -g root -m 0644 "$source_root/overlay/etc/systemd/system/$mount_unit" "/etc/systemd/system/$mount_unit"
mkdir -p /mnt/omabox-config
systemctl daemon-reload
systemctl enable "$mount_unit"
printf '4\n' > /usr/local/share/omabox/image-version
echo 'Integration is updated. Shut down Linux and start it again from the updated Mac app to apply configuration files.'
