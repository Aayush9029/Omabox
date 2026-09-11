# Validation

Validated on September 10–11, 2026 using an Apple M4 Pro MacBook Pro with 14 CPU cores and 48 GiB RAM, macOS 27 beta `26A428`, and Xcode 27 beta 6. The application deployment target is macOS 26.0 and the executable contains only arm64 code.

## Release build

The Developer ID signed Release build passes strict recursive signature verification. App Sandbox and Hardened Runtime are enabled. The final app has virtualization, outbound networking, microphone input, and user-selected file/bookmark entitlements. It does not have debugger attachment, JIT, unsigned executable memory, library validation exceptions, or bridged networking entitlements. Debugger attachment remains available for Debug builds and tests. Notarization and installation on a second Mac have not been performed.

## Native guest

`Scripts/check-guest.sh` completed three actual Apple Virtualization boots using disposable copies of the factory image. The checks verified Hyprland and Quickshell rendering, PipeWire and desktop portal startup, a Virtio sound playback device, VirtioFS mounting, and exact text clipboard transfer in both directions over Virtio sockets. No user service failed in the checked desktop sessions.

Native display scale and rendering-thread preferences were applied on boot. User overrides were then changed inside Linux, followed by another shutdown and boot. Both override files retained their checksums and their values took precedence over the host defaults.

The clipboard agent's 16 protocol and subprocess tests passed both on the host and inside the bundled Linux guest. A separate read-only factory audit verified that the installed agent matches its source, the raw disk still matches the manifest checksum, first-owner provisioning remains pending, and no QA account is included in the factory image.

Evidence is in `Artifacts/guest-qa-4n9bfs92/verification.log`, `customization.log`, and `exports/`. The unmodified `desktop-native.png` capture is also bundled as `OmarchyPreview.png`.

The final factory disk has SHA-256 `f66619d9a3eceb3478c49954d2d0b01ea1bf429431a476403a3901ea37b8b3ca`. Its kernel, initramfs, and disk checksums also match the files inside the signed Release app. Fresh disposable copies passed desktop startup, clipboard exchange, customization persistence, DNS and certificate-verified HTTPS, host read-only folder enforcement, writable-file persistence across cold boots, and 96,000 silent stereo PCM frames through Virtio sound. The test helper discarded audio at the host sink; this does not validate physical speaker output.

The event-driven guest display service passed startup catch-up, live resolution changes, preserving 2× scale, opt-out at startup and during a session, re-enabling, and a rapid twelve-request sequence ending at the latest size. All 22 display-service unit tests passed. Fresh-factory compositor dimensions and screenshots confirmed 1024×768 and 1440×900 modes. The pinned Linux mode generator rounds widths down to multiples of eight. Reports are in `Artifacts/guest-reliability-2l08tgcx/display-sync-report.json` and `Artifacts/guest-reliability-vysudswg/host-report.json`.

## Unit tests

All 41 Swift test functions passed, covering 43 cases after expanding parameterized installation tests, with zero recorded issues. Coverage includes atomic installation and corruption rejection, preserving existing disks, VM lifecycle failures, exclusive disk ownership, resource limits, preference migration, clipboard framing, weighted command search, modifier normalization, native reserved-key dispatch, and guest focus revocation/reentry. The overnight regressions cover a late failure from a superseded startup, quitting during a suspended pause, canceling that quit wait, and canceling Quit during a delayed resume without requesting shutdown afterward.

The latest run used a fresh Debug build-for-testing and loaded its app library and test bundle through Swift Testing's stable tools ABI. A minimal AppKit context with activation prohibited supported the hidden-window input tests. It did not launch Omabox's application entry point or require the stalled Xcode test daemon. Evidence, tested binary hashes, raw events, and exact invocation are in `Artifacts/Overnight/UI/quit-resume-regression/`; the process exited 0. The runner methodology is documented in `Artifacts/Overnight/UI/UnitTesting.md`. The earlier 39-case Xcode run is preserved separately in `Artifacts/Validation/unit-results.json`.

## Native application interaction

Computer-use checks exercised the signed sandboxed Release app itself. The home page uses the Helm split layout and real Omarchy assets. CPU, memory, clipboard, display scale, configuration search, and Settings synchronization were verified through native controls. Saved preferences survived quitting and relaunching. Resource controls expose individual accessibility identifiers and native increment/decrement actions in both home and Settings.

The app created its private disk from the bundled template and booted to the actual Omarchy first-owner screen. No personal Linux account was created. Pause, resume, graceful shutdown, and returning to the editable home page were exercised. Command-K is unavailable before launch and after shutdown.

Command-K was opened from guest keyboard focus with system-key capture both enabled and disabled. Search received focus automatically and accepted typing without a click, including one uninterrupted open-and-type sequence and a rapid Escape → Command-K → type sequence. Searching `memory` selected Configure machine above Pause. Arrow selection, Return opening Machine settings, no-result recovery, Escape dismissal, shutdown from the palette, and Control-Option-Escape followed by the host Settings shortcut were verified. The original keyboard-capture preference was restored afterward.

The overnight native pass verified Light and Dark appearance, the opaque Reduce Transparency fallback, and opening and immediately typing into Command-K with Reduce Motion enabled. It found and corrected the home button's foreground contrast in Light Mode. The native toolbar now exposes named Settings and Command palette buttons. The original Dark appearance, Reduce Motion off, and Reduce Transparency off preferences were restored and read back through System Settings.

A dedicated empty QA folder was selected through the sandbox's normal folder picker. Its name and default read-only choice survived quitting and relaunching, and the saved bookmark was accepted when starting the real VM. Quitting while the guest was paused resumed Linux, requested a clean shutdown, and exited the application. The QA folder selection was removed afterward; microphone access remained off. The home layout also rendered correctly in full screen. Control-Command-F entered and exited full screen using the standard native menu action; Escape also returned to the normal window.

The empty first-owner desktop created during earlier QA was preserved under `Guest-QA-Previous-2026-09-11` beside the app's active installation. The signed Release app then installed the final factory through its normal Set Up action and reached first-owner setup. No personal Linux account was created. The VM was shut down cleanly, leaving the home page ready to start the latest guest. `Artifacts/Overnight/native-ui-checks.json` records the native checks. Completed disposable VM disk and boot files were removed using the exact cleanup manifest; all reports, screenshots, and logs remain.

## Performance observations

With the Machine settings page idle in Light appearance and Reduce Transparency enabled, a 20-second process-counter sample measured stable 163 MiB resident memory and 78 MiB physical footprint, six interrupt wakeups, no disk I/O or page-ins, and less than 0.01% of one CPU core. This is a short observation of one host UI state, not a general performance guarantee. No Instruments trace was captured. Raw counters, methodology, and limitations are in `Artifacts/Overnight/Performance/README.md`.

The two static home images are decoded once per process. A repeated in-memory decode benchmark found no median-time improvement from generating a thumbnail, so the existing cached loader was retained.

The final guest helper used four virtual CPUs, 4 GiB memory, and two software-rendering threads. Two cold boots reached the desktop in 6.77 and 6.38 seconds. Three pauses took 4.65–4.85 milliseconds, and resumes took 0.245–0.309 milliseconds. A 20-second idle sample consumed 1.75% of one core across the helper and VM service, with concurrent Xcode build activity. These measurements apply to the test helper configuration, not every host, application workload, or the app's default 8 GiB configuration.

## Test environment limits

The 11 XCUITests have been typechecked. The final selected UI run did not reach its test because the macOS beta runner timed out while enabling automation mode. Earlier attempts also encountered accessibility authorization and helper disconnection errors. Native computer use supplied the interaction checks; the automated UI suite is not reported as passing.

Physical microphone recording, guest audio playback to a physical output device, browser screen-share selection, non-US keyboard layouts, external display changes, host sleep/wake, and execution on macOS 26 hardware remain unverified. Linux graphics use llvmpipe software rendering through Apple's Virtio framebuffer; no Linux GPU acceleration is claimed.
