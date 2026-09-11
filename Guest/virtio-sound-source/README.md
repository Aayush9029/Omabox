# Virtio sound for the Omabox guest

This directory contains the unmodified `sound/virtio` driver from [Linux v7.2.2](https://github.com/gregkh/linux/tree/52c36105f76e96b638152a42e735f2e7767ed946/sound/virtio), pinned to commit `52c36105f76e96b638152a42e735f2e7767ed946`. The annotated release tag is `b6f54d701a4feab97077600d2d489754a8cc0f43`. The files retain their upstream GPL-2.0-or-later license notices; the [upstream license text](https://github.com/gregkh/linux/blob/52c36105f76e96b638152a42e735f2e7767ed946/LICENSES/preferred/GPL-2.0) applies.

`provenance.json` records the source URL, Git blob ID, and SHA-256 digest of every upstream file. The original Kbuild Makefile also supports an external module build. All Linux and ALSA headers come from the guest's matching `linux-aarch64-headers` package.

## Build and install inside the guest

These commands target exactly `7.2.2-2-aarch64-ARCH`. Copy this directory into the guest at `/tmp/virtio-sound-source` first. The kernel must already have `CONFIG_VIRTIO`, `CONFIG_SND_PCM`, and `CONFIG_SND_JACK` enabled. Building the external driver does not enable those dependencies.

Run as root inside the guest:

```sh
set -eu
test "$(uname -r)" = '7.2.2-2-aarch64-ARCH'
cd /tmp/virtio-sound-source
sha256sum --check SHA256SUMS
test -f /lib/modules/7.2.2-2-aarch64-ARCH/build/include/uapi/linux/virtio_snd.h
make -C /lib/modules/7.2.2-2-aarch64-ARCH/build M=/tmp/virtio-sound-source CONFIG_SND_VIRTIO=m modules
test "$(modinfo -F vermagic ./virtio_snd.ko | cut -d ' ' -f 1)" = '7.2.2-2-aarch64-ARCH'
install -Dm644 virtio_snd.ko /usr/lib/modules/7.2.2-2-aarch64-ARCH/updates/virtio_snd.ko
depmod -a 7.2.2-2-aarch64-ARCH
modprobe virtio_snd
cat /proc/asound/cards
cat /proc/asound/pcm
```

The module's Virtio device alias allows normal device-based loading on later boots. The VM must expose a Virtio sound device for an ALSA card to appear. Confirm playback and recording separately in a normal desktop session using PipeWire and the VM's configured audio streams.

An updated guest kernel needs a module built against its own matching source and headers. Do not copy this compiled module into another kernel's module directory.
