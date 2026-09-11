# Virtio sound

Unmodified [Linux v7.2.2 sound/virtio source](https://github.com/gregkh/linux/tree/52c36105f76e96b638152a42e735f2e7767ed946/sound/virtio), commit `52c36105f76e96b638152a42e735f2e7767ed946`, annotated tag `b6f54d701a4feab97077600d2d489754a8cc0f43`. Upstream GPL-2.0-or-later notices apply; see [COPYING](COPYING) and [license text](LICENSES/preferred/GPL-2.0). [provenance.json](provenance.json) records each file's source URL, Git blob ID, and SHA-256.

Copy this directory to `/tmp/virtio-sound-source` in the guest. Use the matching `linux-aarch64-headers` package for all Linux/ALSA headers. The kernel must already enable `CONFIG_VIRTIO`, `CONFIG_SND_PCM`, and `CONFIG_SND_JACK`; an external module cannot enable them.

Run as root for exactly `7.2.2-2-aarch64-ARCH`:

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

The upstream Kbuild Makefile supports this external build. The Virtio alias loads the module on later boots; an ALSA card requires a VM sound device. Verify playback and recording separately through PipeWire and the configured VM streams.

For a different kernel, rebuild with matching source and headers. Never reuse this compiled module in another kernel's module directory.
