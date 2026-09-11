# Validation

Validated on September 10–11, 2026 using an Apple M4 Pro MacBook Pro with 14 CPU cores and 48 GiB RAM, macOS 27 beta `26A428`, and Xcode 27 beta 6. The application deployment target is macOS 26.0 and the executable contains only arm64 code.

## Current revision status

The 182-case Swift suite and all 122 Python checks passed. The corrected factory `0.4.0`, integration version `4`, passed startup, adaptive-resolution, configuration-reload recovery, and SSH smoke checks. Native Home, TextEdit, and actual guest 512 × 320 and 1440 × 900 menu checks passed. Developer ID signed build `0.1.0 (9)` completed archive and export with the corrected factory verified in both outputs. The README screenshots still show build 5. Results from preceding revisions are identified separately below.

## Release build

The final Developer ID signed build `0.1.0 (9)` passes strict signature and release checks. It contains only arm64 code, targets macOS 26, and has App Sandbox, Hardened Runtime, and a secure signing timestamp. The app has virtualization, outbound networking, microphone input, and user-selected file/bookmark entitlements. It does not have debugger attachment, JIT, unsigned executable memory, library validation exceptions, or bridged networking entitlements. Debugger attachment remains available for Debug builds and tests.

The archive is `build/Archives/Omabox-0.1.0-9.xcarchive`; the exported app is `build/Export/Omabox-0.1.0-9/Omabox.app`. Both contain the corrected factory `0.4.0`, integration version `4`, with disk SHA-256 `8b2a11ab8efb6ab038e963b7f56244e59d2045b3eec6e8dfd802137416f0b30a`. The signing identity is Developer ID Application: Aayush Pokharel (`4538W4A79B`). Archive and export logs are `/tmp/omabox-production-archive-build9.roIeIw` and `/tmp/omabox-production-export-build9.7srK8Z`. Notarization and installation on a second Mac have not been performed.

## Native guest

The adaptive-scaling matrix passed on a disposable guest upgraded from integration 3 to integration 4. It verified all five pixel presets and their compositor scales: 512 × 320 at 0.5×, 960 × 600 at 0.75×, 1280 × 800 at 1×, 1440 × 900 at 1.25×, and 1920 × 1200 at 1.5×. Four arbitrary Fit to Screen requests followed the actual DRM framebuffer, including native width rounding. Rapid resize requests settled on the latest size. Dynamic-resolution opt-out, re-enabling, explicit environment scales, and Lua monitor rules preserved manual control. The report is `Artifacts/guest-scaling-_ww2gf29/scaling-report.json`, with `passed: true` and confirmed shutdowns.

That matrix also identified a Linux limitation: after a managed custom DRM modeline, a live manual mode rule can retain Hyprland's prior timing. The synchronizer stops changing manual configurations, and the requested manual modes passed after a cold boot.

The corrected factory `0.4.0`, integration version `4`, has disk SHA-256 `8b2a11ab8efb6ab038e963b7f56244e59d2045b3eec6e8dfd802137416f0b30a`. It passed startup with blank host configuration and exact installed display-source hash checks. Automatic scaling passed at 512 × 320 at 0.5×, 1440 × 900 at 1.25×, and 2560 × 1600 at 2×. A configuration reload restored the adaptive 1.25× scale without another native resize; process identity, restart count, and log count stayed unchanged during the following three-second idle check. SSH accepted a pinned non-root login after authorization, then closed its managed listener and removed authorization after disable. The report is `Artifacts/guest-scaling-5cpvvq00/final-factory-smoke-report.json`, with `passed: true` and confirmed shutdown.

The earlier upgraded-guest reload regression also confirmed fixed 1.25× scale and a manual 1024 × 768 at 1× rule remained in effect. Its evidence is `Artifacts/guest-scaling-_ww2gf29/scaling-reload-report.json`, with `passed: true` and confirmed shutdown. The runtime handles Hyprland configuration-reload events without idle polling. An advanced live Lua evaluation that switches a monitor rule to `scale = 'auto'` can require a configuration reload when the framebuffer dimensions have not changed; the normal editor workflow reloads configuration or restarts Linux.

The following configuration and SSH results cover the earlier `0.3.0` factory, integration version `3`, with disk SHA-256 `7caa1d08ced52c191aa3cceb84015a8e9e5ee67cf2f5751af70e275d6e6d79cb`.

Factory `0.3.0` passed four desktop boots covering defaults, empty host files, explicit host overrides, and malformed host Lua. Empty Mac files preserved guest preferences. Explicit Mac values changed rendering threads from two to one, GDK scale from one to two, and inner gaps from three to seven while preserving the guest files. Malformed host Lua left the desktop running with its guest configuration, and shell-like environment values remained literal. Host dynamic-resolution settings overrode conflicting guest settings during actual resize checks.

The guest owner could read files exposed from a Mac directory with mode 0700 and files with mode 0600. A guest-root write through `/mnt/omabox-config` failed with `EROFS`. Running the combined integration updater twice preserved existing preference files. The report is `Artifacts/guest-configuration-_36hhs0v/configuration-report.json`, with `passed: true` and a confirmed shutdown for every boot.

The same `0.3.0` factory passed the complete SSH regression: real non-root SSH and SFTP, root/password/wrong-key rejection, active-session revocation while the desktop survived, pending-owner handling, cold-boot disable and reauthorization, persistent host keys, and actual guest display changes. Its updater preserved integration version 3. `Artifacts/guest-ssh-a6k363zf/ssh-report.json` records `passed: true` and confirmed shutdown. The factory release verifier also passed.

The remaining guest observations in this section cover earlier factory revisions.

`Scripts/check-guest.sh` completed three actual Apple Virtualization boots using disposable copies of the factory image. The checks verified Hyprland and Quickshell rendering, PipeWire and desktop portal startup, a Virtio sound playback device, VirtioFS mounting, and exact text clipboard transfer in both directions over Virtio sockets. No user service failed in the checked desktop sessions.

Native display scale and rendering-thread preferences were applied on boot. User overrides were then changed inside Linux, followed by another shutdown and boot. Both override files retained their checksums and their values took precedence over the host defaults.

The clipboard agent's 16 protocol and subprocess tests passed both on the host and inside the bundled Linux guest. A separate read-only factory audit verified that the installed agent matches its source, the raw disk still matches the manifest checksum, first-owner provisioning remains pending, and no QA account is included in the factory image.

Evidence is in `Artifacts/guest-qa-4n9bfs92/verification.log`, `customization.log`, and `exports/`, including the unmodified `desktop-native.png` capture.

The earlier factory disk with SHA-256 `f66619d9a3eceb3478c49954d2d0b01ea1bf429431a476403a3901ea37b8b3ca` matched the kernel, initramfs, and disk bundled in the earlier signed Release app. Fresh disposable copies passed desktop startup, clipboard exchange, customization persistence, DNS and certificate-verified HTTPS, host read-only folder enforcement, writable-file persistence across cold boots, and 96,000 silent stereo PCM frames through Virtio sound. The test helper discarded audio at the host sink; this does not validate physical speaker output.

The event-driven guest display service passed startup catch-up, live resolution changes, preserving 2× scale, opt-out at startup and during a session, re-enabling, and a rapid twelve-request sequence ending at the latest size. All 22 display-service unit tests passed. Fresh-factory compositor dimensions and screenshots confirmed 1024×768 and 1440×900 modes. The pinned Linux mode generator rounds widths down to multiples of eight. Reports are in `Artifacts/guest-reliability-2l08tgcx/display-sync-report.json` and `Artifacts/guest-reliability-vysudswg/host-report.json`.

Earlier factory version `0.2.0`, integration version `2`, had disk SHA-256 `3e0714580d1e041e0900ecda010a51770ce70992592e96a804ef3956bf881639`. Its disposable native guest passed real non-root SSH login over the Mac's NAT connection and SFTP with a pinned host key. Root login, password authentication, and incorrect or replaced keys were rejected. Replacing the key or disabling access terminated existing SSH sessions while the owner's desktop stayed running. Pending-owner state kept the listener closed. A cold boot left SSH disabled until host reauthorization, and the guest host key persisted across reboot.

The manual integration updater preserved the recorded owner, removed managed authorization, and left SSH disabled without replacing the guest disk. The same run confirmed an actual 512 × 320 Hyprland mode and restoration to 1440 × 900. Evidence is in `Artifacts/guest-ssh-klrgvszz/ssh-report.json`, which records `passed: true` and confirmed shutdown. These checks used disposable keys and a disposable guest.

## Unit tests

All 124 Swift test functions passed across 15 suites, covering 182 cases after expanding parameterized tests, with zero recorded issues. Coverage includes atomic installation, disk preservation, VM lifecycle failures, exclusive disk ownership, resource limits, preference migration, clipboard framing, command search, input routing, and immediate host-menu focus. The current regressions also cover native window-update recovery after SwiftUI clears size limits, preservation of full-screen and resolution state, native home/runtime geometry, resolution navigation, SSH lifecycle and filesystem ownership, Linux configuration file creation, starter text, preservation, validation, and editor errors, and six animated-image lifecycle cases.

The latest run used a fresh Debug build-for-testing and loaded its app library and test bundle through Swift Testing's stable tools ABI. A minimal AppKit context with activation prohibited supported hidden-window geometry, real SwiftUI hosting, and immediate-focus regressions. It did not launch Omabox's application entry point, start a VM, or require the stalled Xcode test daemon. Evidence, tested binary hashes, raw events, exact invocation, and counted completions are in `Artifacts/Overnight/UI/animation-config-regressions/`; the process exited 0. The runner methodology is documented in `Artifacts/Overnight/UI/UnitTesting.md`. Earlier runtime/SSH, palette-focus, and quit/resume runs remain in their artifact directories, and the 39-case Xcode run is preserved separately in `Artifacts/Validation/unit-results.json`.

All 122 Python checks passed: 82 guest-service tests, 16 clipboard-service tests, and 24 release-verifier tests. The final `Scripts/ci.sh guest` run exited 0; its log is `/tmp/omabox-final-guest-ci.log`. This run includes the configuration-reload fix.

## Native application interaction

The runtime interface now uses **Control-Option-Command-K** (**⌃⌥⌘K**) for the host menu in running and paused states. Plain **Command-K** passes through to the guest. The menu includes Settings, power controls, and Release Keyboard, with Resume replacing Pause while paused.

The current revision uses bottom-left shortcut text with a five-second timeout and hidden native traffic lights. Its fixed 880 × 560 Home and pixel-resolution menu are described in [the build guide](Build.md).

Native checks confirmed Home is 880 × 560. Selecting eight CPUs and 12 GiB memory through the segmented selectors produced eight cores and 12 GiB in Machine settings; the choices were restored to four CPUs and 8 GiB afterward. Disk capacity appeared as noneditable 40 GiB text. Settings appears above Start and opened General. The Environment and Desktop editor rows displayed their distinct icons.

Both Environment and Desktop editor actions opened the QA app's actual configuration files in native TextEdit with their starter instruction lines. Appending `OMABOX_EDITOR_QA=literal` to `desktop.env` and saving produced the exact expected plain text with mode 0600, verified from the filesystem. The environment file was restored to its starter line afterward. These checks used isolated QA data and did not change production user data.

With the current interface and an integration-4 guest, selecting the 512 × 320 and 1440 × 900 presets through the actual app host menu produced those Linux framebuffer dimensions with scales 0.5× and 1.25×. SSH queries recorded the compositor state in `Artifacts/native-ssh-ui/adaptive-native-320.json` and `Artifacts/native-ssh-ui/adaptive-native-900.json`. Disabling SSH restored the original configuration exactly and removed the managed files, leaving only the baseline configuration and two disposable key files. Guest shutdown returned the app to Home, and a process check confirmed the app exited. The summary is `Artifacts/native-ssh-ui/adaptive-native-verification.json`.

The following application/guest integration checks cover preceding builds.

The integration-3 native configuration pass wrote a QA-only `OMABOX_UI_CONFIGURATION_CHECK=from_mac_editor` entry before starting the integration-3 guest through the app's actual Virtualization runtime. SSH inspection confirmed the value in Hyprland's process environment and readable `desktop.env` contents at `/mnt/omabox-config`. The report is `Artifacts/native-ssh-ui/configuration-native-report.json`. The managed SSH connection worked with the new guest's host key; disabling it through the UI restored the original SSH configuration and removed the managed files. The guest shut down gracefully, the app quit, and the QA configuration was reset to empty. Production guest files were not changed.

The earlier native SSH pass selected `Artifacts/native-ssh-ui/ssh` through the normal folder picker, which selected `omabox_qa.pub` automatically. Enabling access displayed SSH configured for `omaboxqa`. Executing the app's displayed custom-folder command, `ssh -F …/config omabox`, connected as UID 1000 and user `omaboxqa`. The original SSH configuration was preserved while Omabox created its managed configuration and pinned known-hosts files. Disabling access through the UI showed SSH off, closed TCP port 2222, restored the baseline configuration byte for byte, and removed the managed files. No personal SSH files were used.

The earlier native resolution pass selected 512 × 320 through the host menu. `CGWindowList` reported a 512 × 320 native window, and `hyprctl monitors` queried through SSH confirmed the same actual guest pixel dimensions; the guest response is in `Artifacts/native-ssh-ui/display-320p.json`. The 1440 × 900 preset restored the larger desktop. Immediate typing into the host menu and its Resolution submenu worked, including searching `320` and pressing Return to select it. Down → Down → Return opened General settings.

The same earlier native pass also verified the full material pause overlay and Resume action, hidden runtime traffic lights, and shortcut text disappearing after inactivity. After guest shutdown, the Home Settings button opened General even though Sharing had previously been selected. The QA guest shut down cleanly and the app quit. This pass did not touch the original user guest.

Full-screen transition recovery was exercised through the host menu: Toggle full screen, followed by Resolution → 512 × 320, returned a native 512 × 320 window without an error alert. The implementation reconciles AppKit's actual full-screen state after a failed transition and retains the selected resolution before requesting an exit.

These checks do not establish a guest application's response to plain Command-K or the shortcut control's VoiceOver and accessibility-focus behavior. The remaining live checks are recorded in [the testing guide](Testing.md).

## Earlier native checks

Earlier signed builds verified home/settings preference synchronization and persistence, native stepper accessibility, setup to the first-owner screen, sandbox folder selection and bookmark reuse, and clean quit while paused. Light and Dark appearance, Reduce Transparency, and Reduce Motion were checked, and the original system settings were restored. Evidence is in `Artifacts/Overnight/native-ui-checks.json`. The older configuration-search and toolbar layouts were subsequently replaced, so those layout checks do not validate the current interface.

Build 3 verified Control-Option-Command-K from guest focus with keyboard capture enabled, complete immediate `release keyboard` input, rapid Escape → open → `microphone` input, arrow/Return navigation, paused-menu resume, and menu-driven clean shutdown. Plain Command-K did not open the host menu. Capture was restored to off, microphone stayed off, and clipboard stayed on. These observations supplement the later native passes and the compiled focus regressions.

## README screenshot method

The README contains exactly two images captured from Developer ID signed build 5, `Docs/images/home.png` and `Docs/images/settings.png`. Each is an opaque 2240 × 1440 PNG showing the actual desktop wallpaper on the same 1120 × 720-point canvas. Home is centered at 880 × 560 points and Settings at 720 × 500 points. Other windows were hidden, and Home was minimized for the Settings capture.

Each native ScreenCaptureKit capture started with a five-second timer; the target window was then raised and focused through its noninteractive content or General settings. Only CUA's software cursor overlay windows were excluded by the capture filter. Both images were inspected and show focused traffic lights, clean wallpaper, and no cursors or other windows. They depict build 5; a capture of the current layout is pending because desktop visibility prevented a clean refresh.

## Performance observations

Six current animated-image lifecycle tests passed. A native sample with Settings occluded measured zero CPU over 20 seconds. Visible animation playback remains inconclusive because the window was on another Space or behind Mission Control during inspection. An earlier build-7 sample measured about 14% CPU with Settings closed and identified GIF work; that observation motivated the lifecycle correction. No successful current visible-playback regression is claimed.

In an earlier revision, with the Machine settings page idle in Light appearance and Reduce Transparency enabled, a 20-second process-counter sample measured stable 163 MiB resident memory and 78 MiB physical footprint, six interrupt wakeups, no disk I/O or page-ins, and less than 0.01% of one CPU core. This is a short observation of one host UI state, not a general performance guarantee. No Instruments trace was captured. Raw counters, methodology, and limitations are in `Artifacts/Overnight/Performance/README.md`.

The home page's Omarchy mark is decoded once and cached for the process lifetime.

An earlier guest helper used four virtual CPUs, 4 GiB memory, and two software-rendering threads. Two cold boots reached the desktop in 6.77 and 6.38 seconds. Three pauses took 4.65–4.85 milliseconds, and resumes took 0.245–0.309 milliseconds. A 20-second idle sample consumed 1.75% of one core across the helper and VM service, with concurrent Xcode build activity. These measurements apply to the test helper configuration, not every host, application workload, or the app's default 8 GiB configuration.

## Test environment limits

The 13 XCUITest functions have been compiled. The selected UI run did not reach its test because the macOS beta runner timed out while enabling automation mode. Earlier attempts also encountered accessibility authorization and helper disconnection errors. Native computer use supplied the interaction checks; the automated UI suite is not reported as passing.

The final pass did not rerun workflow lint because `actionlint` was unavailable on the current PATH. The workflows were unchanged after their earlier review.

Physical microphone recording, guest audio playback to a physical output device, browser screen-share selection, non-US keyboard layouts, external display changes, host sleep/wake, and execution on macOS 26 hardware remain unverified. Linux graphics use llvmpipe software rendering through Apple's Virtio framebuffer; no Linux GPU acceleration is claimed.
