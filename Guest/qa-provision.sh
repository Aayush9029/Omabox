#!/bin/bash
set -euo pipefail
[[ -f /var/lib/omarchy/provisioning/pending && $(cat /etc/hostname) == omabox ]]
[[ ! -e /home/omaboxqa ]]

useradd -m -G wheel,video,audio,input -s /bin/bash -c 'Omabox disposable QA' omaboxqa
printf 'omaboxqa:%s\n' "$(head -c24 /dev/urandom | base64)" | chpasswd
printf 'omaboxqa ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/99-omabox-qa
chmod 0440 /etc/sudoers.d/99-omabox-qa
runuser -u omaboxqa -- env \
  HOME=/home/omaboxqa USER=omaboxqa LOGNAME=omaboxqa SHELL=/bin/bash \
  OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL=/usr/share/omarchy/install \
  OMARCHY_SETUP_CONTEXT=provision-owner OMARCHY_USER_NAME='Omabox QA' \
  OMARCHY_USER_EMAIL='' OMARCHY_LOG_TO_STDOUT=1 \
  /usr/share/omarchy/bin/omarchy-provision-user --force --first-install

mkdir -p /etc/sddm.conf.d /etc/systemd/system/serial-getty@hvc0.service.d
printf '[Autologin]\nUser=omaboxqa\nSession=omarchy.desktop\n' >/etc/sddm.conf.d/autologin.conf
printf '[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin root --noclear %%I $TERM\n' >/etc/systemd/system/serial-getty@hvc0.service.d/qa.conf
rm /var/lib/omarchy/provisioning/pending
systemctl --root=/ enable serial-getty@hvc0.service
echo OMABOX_QA_PROVISIONED
