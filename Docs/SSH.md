# SSH access

SSH is optional and uses the non-root account created during Omarchy's first-owner setup.

1. Open **Settings → Sharing → SSH Access**.
2. Choose an **SSH Folder**, select its `.pub` **Public Key**, and enable access.
3. Keep `omabox` or change the alias with **Apply Alias**.
4. Use **Copy SSH Command**. **Refresh Connection** retries setup.

With `~/.ssh`:

```sh
ssh omabox
```

For a custom folder:

```sh
ssh -F '/path/to/selected-folder/config' omabox
```

The SSH folder is never shared with Linux. Omabox reads only public-key contents; private-key contents are never read or shared. Your Mac's SSH client uses the matching private key.

Connections pin the guest host key. The guest accepts public-key authentication on port 2222; password and root login are disabled.

Disabling access revokes guest access and removes unchanged Omabox-managed configuration, preserving unrelated entries and independently edited contents. Cold boots require authorization from the app again.

Older desktops may need the [guest integration updater](../Guest/README.md). See [validation](Validation.md) for coverage.
