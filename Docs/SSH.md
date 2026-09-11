# SSH access

The guest SSH service has passed real SSH and SFTP checks from the Mac against a disposable Linux installation, including authentication rejection, revocation, cold-boot behavior, and the existing-desktop updater. The native Sharing-settings flow also passed using a disposable SSH folder and keypair. See [validation results](Validation.md) and [the testing guide](Testing.md) for coverage and remaining checks.

## Configure access

1. Complete Omarchy's first-owner setup so the desktop has a non-root owner account.
2. Open **Settings → Sharing → SSH Access**. Choose an **SSH Folder** and select a **Public Key** from that folder.
3. Enable **Enable SSH access**. Omabox installs the selected public key for the guest's owner account and prepares the connection details. If owner setup is still pending, SSH setup waits for it.
4. Use the default **Host Alias**, `omabox`, or change it and select **Apply Alias**. Use **Refresh Connection** to retry discovery and configuration, then **Copy SSH Command** to copy the command for the selected folder.

Selecting the Mac's usual `~/.ssh` folder allows the standard command:

```sh
ssh omabox
```

For a different folder, the copied command selects that folder's configuration explicitly:

```sh
ssh -F '/path/to/selected-folder/config' omabox
```

Use the command provided by the app for your folder and alias. Connection status indicates setup progress; a successful SSH login is the verification that authentication and guest networking work.

## Keys and configuration

The selected SSH folder is separate from the shared Mac folder and is never mounted into Linux through VirtioFS. The app reads valid `.pub` files to populate the key picker, then rereads the chosen public key before installation. The matching private key's basename is referenced through `IdentityFile`; the app does not read or transfer private key contents. The Mac's SSH client uses that private key when connecting.

Omabox adds an Include entry to the selected folder's `config` and manages `omabox.conf` and `omabox_known_hosts` beside it. The managed configuration pins the guest host key with `StrictHostKeyChecking`. Unrelated SSH entries are preserved. Disabling the integration removes only files and configuration owned by Omabox that still match the managed contents; it preserves independently edited content.

The guest configuration channel uses Virtio socket port 4041 and accepts the host endpoint only. It installs the public key for the recorded first-owner account. A separate guest SSH service uses port 2222 with public-key authentication; password authentication and root login are disabled. The service waits for a valid non-root owner instead of selecting an arbitrary Linux account.

## Existing desktops

An existing private Linux disk is preserved when the app's bundled factory changes. A desktop created before the SSH integration may therefore lack its guest service. The app reports unavailable guest support after a bounded attempt.

To add the service to an existing desktop, finish first-owner setup and share this repository with Linux through Omabox's normal folder picker. From a terminal inside Linux, run:

```sh
sudo bash /mnt/omabox/Guest/install-integration.sh
```

Adjust the path if the selected shared folder is the `Guest` directory itself or another parent. The installer checks that it is running in an Omabox ARM64 guest with systemd. It uses the recorded owner or the exact first-owner identity from the guest's root autologin configuration and stops if that identity cannot be established.

The installer updates Omabox's managed SSH, startup, display, and configuration-mount files and units. It preserves the guest's preference files and stops the managed SSH service while updating, then starts the control agent with SSH access disabled. Shut Linux down and start it from the updated Mac app to attach the separate configuration share. If SSH access is already enabled in the Mac app, the next bounded poll reconfigures the guest; **Refresh Connection** requests a retry. Otherwise, enable SSH access afterward. The installer does not replace the Linux disk or install a personal account.

## Verified guest behavior

Factory version `0.3.0` with integration version `3` passed non-root SSH login and SFTP using a pinned host key. Root login, password authentication, incorrect keys, and replaced keys were rejected. Key replacement and disabling access terminated open SSH sessions without stopping the owner's desktop. An incomplete owner setup kept the listener closed.

A cold boot left SSH disabled until host reauthorization, while retaining the same guest host key. The integration updater preserved the owner record and integration version 3, and left managed SSH access disabled. The disposable guest was shut down cleanly after testing. The report is `Artifacts/guest-ssh-a6k363zf/ssh-report.json`; the earlier integration-2 run remains in `Artifacts/guest-ssh-klrgvszz/ssh-report.json`.

The combined integration updater was subsequently run twice on factory `0.3.0`, preserving the guest's preference files both times. That result is recorded in `Artifacts/guest-configuration-_36hhs0v/configuration-report.json`.

The native app pass selected a disposable folder through the system picker, selected its public key, and enabled access from Sharing settings. The displayed custom-folder SSH command connected as the non-root owner with UID 1000. The baseline SSH configuration stayed intact while managed alias and pinned-host files were present. Disabling access through the UI restored that baseline byte for byte and removed the managed files. No personal SSH files were used.
