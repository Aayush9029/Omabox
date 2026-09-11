#!/bin/bash
set -euo pipefail

if [[ $(id -u) != 0 || $(uname -m) != aarch64 || $(cat /proc/1/comm) != systemd ]]; then
  echo 'Run this updater with sudo inside the running Omabox Linux desktop.' >&2
  exit 1
fi
if [[ ! -f /usr/local/share/omabox/image-version ]]; then
  echo 'This updater requires an existing Omabox Linux disk.' >&2
  exit 1
fi
if [[ -e /var/lib/omarchy/provisioning/pending || -e /var/lib/omarchy/provisioning/wipe-pending ]]; then
  echo 'Finish first-owner setup in Linux before updating SSH integration.' >&2
  exit 1
fi
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for executable in sshd ssh-keygen python3 ip; do
  test -x "/usr/bin/$executable"
done
for script in omabox-ssh-agent.py omabox-record-owner.py; do
  test -f "$source_root/overlay/usr/local/libexec/$script"
done
for unit in omabox-ssh-agent.service omabox-sshd.service; do
  test -f "$source_root/overlay/etc/systemd/system/$unit"
done
owner_dropin=etc/systemd/system/omarchy-provision-owner.service.d/omabox-owner.conf
test -f "$source_root/overlay/$owner_dropin"

install -D -o root -g root -m 0755 "$source_root/overlay/usr/local/libexec/omabox-record-owner.py" /usr/local/libexec/omabox-record-owner.py
if [[ ! -e /var/lib/omarchy/provisioning/pending && ! -e /var/lib/omabox/owner.json ]]; then
  /usr/local/libexec/omabox-record-owner.py
fi
for unit in omabox-sshd.service omabox-ssh-agent.service; do
  if systemctl cat "$unit" >/dev/null 2>&1; then
    systemctl stop "$unit"
  fi
done
install -D -o root -g root -m 0755 "$source_root/overlay/usr/local/libexec/omabox-ssh-agent.py" /usr/local/libexec/omabox-ssh-agent.py
for unit in omabox-ssh-agent.service omabox-sshd.service; do
  install -D -o root -g root -m 0644 "$source_root/overlay/etc/systemd/system/$unit" "/etc/systemd/system/$unit"
done
install -D -o root -g root -m 0644 "$source_root/overlay/$owner_dropin" "/$owner_dropin"
systemctl daemon-reload
systemctl enable --now omabox-ssh-agent.service
current_version=$(cat /usr/local/share/omabox/image-version)
if [[ ! $current_version =~ ^([2-9]|[1-9][0-9]+)$ ]]; then
  printf '2\n' > /usr/local/share/omabox/image-version
fi
echo 'SSH integration is installed. Enable SSH in the Mac app to authorize access.'
