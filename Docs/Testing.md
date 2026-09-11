# Omabox testing

Omabox has two automated test layers. Swift Testing exercises models and service boundaries in `OmaboxTests`; XCUITest exercises the signed native macOS application in `OmaboxUITests`. A passing UI suite proves the host interface, not that a Linux desktop has booted successfully.

## Run the automated suites

Use an Apple silicon Mac with macOS 26 or later and the Xcode version selected for the project. Generate the workspace with the repository's Tuist configuration, then run the shared `Omabox` scheme against **My Mac**. Run UI tests serially, with the Mac unlocked and no concurrent computer automation.

```sh
tuist install
tuist generate --no-open
xcodebuild test -workspace Omabox.xcworkspace -scheme Omabox -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO -resultBundlePath /tmp/Omabox-tests.xcresult
```

Choose a new result bundle path for each run. Use `-only-testing:OmaboxTests` for model tests or `-only-testing:OmaboxUITests` for UI tests. Preserve the `.xcresult` so failures can be reviewed with their screenshots and accessibility hierarchy.

The UI runner launches with `--ui-testing --ui-testing-reset`. This mode must use a separate preferences file and machine directory, inject permission and virtualization dependencies, and suppress login-item registration. Relaunching with only `--ui-testing` preserves the isolated preferences for the persistence test. These arguments must have no effect in Release builds. Tests must never reset the user's ordinary preferences, delete a real machine, ask for microphone permission, or start a real VM.

## Automated acceptance

| Area | Required behavior |
| --- | --- |
| First launch | The fixed 880 × 560-point home identifies Omabox, says Run Omarchy in a virtual machine, and exposes Set Up Omarchy without a permission dialog or automatic guest boot. |
| Home configuration | CPU and memory preset buttons expose the selected choice, update the displayed values, and change the same preferences in Machine settings. Disk capacity is displayed as not editable. The home clipboard switch changes Sharing settings. There is no configuration search or footer version. |
| Home Settings | The subtle Settings action opens General, including after another settings pane was selected previously. |
| Settings | Command-comma opens a single settings window; General, Machine, Sharing, Shortcuts, and About are individually reachable. |
| Persistence | A preference changes immediately and survives a normal application quit and relaunch in the isolated test profile. |
| Sharing | Clipboard and keyboard preferences expose the selected value and can be changed independently without permission prompts. |
| Host menu availability | Control-Option-Command-K opens the host menu only while the desktop is running or paused. Home, setup, startup, and shutdown do not expose it. Plain Command-K is forwarded to the running guest. |
| Host menu actions | Settings, Resolution, power controls, and Release Keyboard are reachable. Pause changes to Resume while paused, and resuming restores Pause. |
| Runtime presentation | The guest fills the window with native traffic lights hidden. The only regular host control is the ⌃⌥⌘K text at the bottom left. Pausing shows a full material overlay, pause symbol, and Resume capsule. |
| Shortcut visibility | Five seconds of inactivity hides the shortcut text. Pointer activity or window focus reveals it. Keyboard accessibility focus and VoiceOver keep it visible. |
| Resolution menu | Resolution offers 512 × 320, 960 × 600, 1280 × 800, 1440 × 900, 1920 × 1200, and Fit to screen. Fixed values represent guest framebuffer pixels; Fit to screen restores automatic display resizing. The menu remains usable at 512 × 320. |
| Layout | Settings preserve the sidebar and minimum content size; each sidebar item is visible and hittable. |
| Accessibility | Native controls expose useful labels, roles, and values. Xcode's accessibility audit finds no action or parent-child failures on the exercised host screens. |
| Linux configuration files | Environment and Desktop have separate editor actions. Preparation creates private empty files, preserves existing contents and modes, and rejects symbolic links or directories in file positions. Model tests inject the editor boundary and verify actionable failures without opening another app. |
| Model behavior | Resource bounds, VM lifecycle transitions, invalid configuration, installation failures, persistence, and command filtering have deterministic Swift Testing coverage. |

## Native visual and interaction pass

Run this pass after the automated suite has stopped. Use native macOS computer automation or Accessibility Inspector; rendered web pages, if needed for documentation, use Safari MCP.

1. Check the settings sidebar width, window minimum size, pane padding, typography, card borders, illustrations, icon assets, material, and animations in General, Shortcuts, and About. The visual components should preserve their intended geometry and remain legible at the minimum window size.
2. Check light and dark appearance on light and dark wallpapers. Enable Reduce Transparency and Increase Contrast, then confirm text remains legible and interactive controls remain distinguishable. Enable Reduce Motion and inspect palette presentation and settings transitions.
3. Verify Home remains 880 × 560 points and cannot be resized. Resize Settings and the runtime window, move them between Retina and external displays, enter and leave runtime full screen, hide and restore the application, and reopen Settings repeatedly. Verify native traffic lights are hidden during the runtime and restored on Home. Shrink the runtime, then shut down and confirm Home restores its fixed size. Check configuration scrolling and the split home layout.
4. Navigate home controls and settings with keyboard only, including Tab, Shift-Tab, arrow keys, and Return. Inspect VoiceOver names and selected preset states. Verify CPU and memory presets update immediately and disk capacity has no edit control. Open Environment and Desktop separately and confirm each uses the correct file. Open a non-General settings pane, close Settings, and use the home Settings button; it must open General. Confirm Control-Option-Command-K remains unavailable before a desktop is running and becomes available in both running and paused states.
5. With a running guest, check the full-window display and bottom-left shortcut text. Wait five seconds without interaction and confirm the text hides. Move the pointer and return focus from another window to verify each reveals it. Repeat with keyboard accessibility focus on the control and with VoiceOver enabled; it must stay visible in both cases. Restore the original accessibility settings afterward.
6. Pause the guest and inspect the full material overlay, pause symbol, and Resume capsule. Open the host menu while paused and verify Resume replaces Pause. Resume through both entry points in separate passes, and verify input returns to the guest.
7. Select every Resolution preset through the host menu and inspect the guest framebuffer dimensions. Confirm preset values do not double on a Retina screen, resizing the Mac window preserves a fixed guest size, and Fit to screen restores automatic changes. At 512 × 320, search, navigate, scroll, select a resolution, dismiss, and reopen the host menu without clipped controls.
8. Capture home, every settings pane, the running display with its shortcut shown and hidden, the paused overlay, and the host menu with results and its empty state. Include the host OS, Xcode version, display scaling, appearance, and accessibility settings with the evidence.

## Real guest integration gates

Use a disposable **ARM64** Linux installation and a test folder containing nonsensitive files. Record the exact guest image source, checksum, kernel, desktop session, Omarchy build or adaptation, and guest integration package versions. Do not describe an x86-only Omarchy image as compatible with Apple's native ARM virtualization path.

| Area | Exercise and evidence |
| --- | --- |
| Installation | Complete the supported installation/import flow from an empty profile. Cancel download or import, interrupt it, retry it, reject an invalid image, and recover without damaging an existing disk. Confirm installation errors explain the next action. |
| Boot and storage | Reach the guest desktop after a cold boot. Create a file, shut down cleanly, reopen the application, and verify it survives. Check firmware/identity persistence. Reject missing or inaccessible disk files without replacing them. |
| Graphics | Verify guest display rendering, resize response, Retina scaling, full screen, text sharpness, and a typical browser/terminal workload. Record whether desktop rendering uses software acceleration; do not infer Linux GPU acceleration from native window rendering. |
| Resolution | Select all five fixed presets and verify both the VZ display's size in pixels and the guest compositor's applied dimensions. Resize the Mac window and confirm the selected guest resolution stays fixed. Select Fit to screen and verify automatic changes resume. Repeat from full screen and at 512 × 320 with the host menu open. |
| Keyboard and pointer | Test letters, modifiers, punctuation, arrows, function keys, copy/paste, non-US layout, held keys, key release when focus changes, pointer scrolling, and the documented host-shortcut escape route. Test capture enabled and disabled. |
| Host menu shortcut | While the desktop is running, open the host menu from guest focus with Control-Option-Command-K, with keyboard capture both enabled and disabled. Verify plain Command-K reaches a guest application with a known binding and does not open the host menu. Open the menu again while paused. After the guest stops, confirm the host shortcut is unavailable. |
| Host menu interaction | Verify an empty query offers commands. Search by title and resource keyword; confirm Configure machine opens Machine settings. Verify a nonmatching query, clearing search, arrow selection, Return, and Escape. Check Settings, Resolution, power controls, and Release Keyboard. While paused, verify Resume replaces Pause and resumes the real guest. |
| Clipboard | With required guest support installed, copy distinct Unicode and multiline text in both directions. Disable sharing, verify isolation, restart the guest, and re-enable it. Check unsupported guest clipboard configurations produce truthful guidance. |
| Audio output | Play guest audio, change the host output device, mute/unmute, suspend/resume where supported, and confirm there is no feedback or continued playback after shutdown. |
| Microphone | Test not-yet-requested, allowed, denied, and later-revoked host permission with explicit human interaction. Enable input in the app, record inside the guest, and confirm disabling input stops delivery. Boot remains possible with microphone access denied. |
| Screen sharing | Test screen capture inside the guest's own compositor/browser when supported. Confirm rendering a VM does not trigger a request for host Screen Recording. Any future host-screen sharing feature requires its own explicit macOS permission flow. |
| Shared folder | Grant access through the system picker. Read from the guest; reject writes when read-only; enable writes and verify a test file. Relaunch the host app, rename/remove the folder, revoke access, and recover through reselection. |
| Linux configuration | Edit Environment and Desktop through their separate host actions. Verify existing host contents survive preparation; empty host files preserve guest preferences; explicit environment and Lua overrides take effect on the next start; and removing an override restores guest behavior. Reject guest writes to the read-only `omabox-config` share. Invalid host files must produce an actionable error. Use a disposable guest and retain before/after file contents. |
| Optional SSH | Use a disposable SSH folder and test keypair. Select the folder and public key through Sharing settings. Verify provisioning waits for the first-owner account, transfers only the public key over host-only vsock 4041, and permits key-only login as that non-root owner on guest port 2222. Reject password and root login. Verify the managed Mac alias and pinned host key work, a mismatched host key is rejected, and unrelated SSH configuration and private key contents remain unchanged. Exercise disable, reconnect, guest restart, and canceled or revoked folder access. Record guest-service and native app results separately; completed checks are in [validation results](Validation.md). |
| Network | Verify NAT internet access, DNS, offline recovery, and guest isolation assumptions. No bridge entitlement or privileged helper should be required for the default connection. |
| Resources | Test accepted CPU, memory, and disk bounds on both a small-memory and larger Apple silicon Mac. Confirm changes that need shutdown are explained and applied on the next boot. Handle insufficient disk space without an incomplete machine appearing ready. |
| Lifecycle | Exercise start, pause/resume if supported, graceful shutdown, shutdown failure, explicit forced stop, closing the window, quitting while running, host sleep/wake, and unexpected guest stop. Each leaves a truthful state and usable recovery action. |
| Sandbox | Run a signed sandboxed build from a fresh user profile. Confirm guest files remain inside app-owned storage and selected folders work through security-scoped access. Inspect the final entitlements and verify hardened runtime signing. |
| Distribution | Build Release for arm64 with deployment target macOS 26. Install the signed/notarized app on a second Mac and repeat onboarding, file selection, microphone denial, guest boot, and persistence. |

## Performance and reporting

Measure release builds on named hardware. Record time to the welcome screen, time to first guest desktop, steady idle host CPU/memory, guest memory allocation, palette latency, resizing responsiveness, and disk usage. Use Instruments to investigate sustained host work while the guest is stopped, main-thread stalls, and retained VM/display objects after shutdown. Repeat measurements with the same guest and resource settings so changes are comparable.

For each validation run, report the build identifier, hardware, host OS, guest versions, automated test counts, result-bundle location, native screenshots, failures, and any unexecuted integration gates. Keep untested hardware/guest behavior explicitly separate from verified host UI behavior. Release requires a successful real guest pass; a rendered welcome screen or mocked test launch is not sufficient.
