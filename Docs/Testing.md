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
| First launch | The Helm-inspired home interface identifies Omabox and exposes Set Up Omarchy without a permission dialog or automatic guest boot. |
| Home configuration | CPU and memory steppers change the displayed values and the same preferences in Machine settings. The home clipboard switch changes Sharing settings. |
| Settings | Command-comma opens a single settings window; General, Machine, Sharing, Shortcuts, and About are individually reachable. |
| Persistence | A preference changes immediately and survives a normal application quit and relaunch in the isolated test profile. |
| Sharing | Clipboard and keyboard preferences expose the selected value and can be changed independently without permission prompts. |
| Command-K availability | Command-K does not open a palette before a desktop is running, from either the home or settings window. The home screen exposes configuration directly. |
| Layout | Settings preserve the Flare sidebar and minimum content size; each sidebar item is visible and hittable. |
| Accessibility | Native controls expose useful labels, roles, and values. Xcode's accessibility audit finds no action or parent-child failures on the exercised host screens. |
| Model behavior | Resource bounds, VM lifecycle transitions, invalid configuration, installation failures, persistence, and command filtering have deterministic Swift Testing coverage. |

## Native visual and interaction pass

Run this pass after the automated suite has stopped. Use native macOS computer automation or Accessibility Inspector; rendered web pages, if needed for documentation, use Safari MCP.

1. Open Omabox and Flare side by side. Compare the settings sidebar width, window minimum size, pane padding, typography, card borders, illustrations, icon assets, material, and animations. Compare General, Shortcuts, and About directly. The copied visual components should preserve their original geometry and assets.
2. Check light and dark appearance on light and dark wallpapers. Enable Reduce Transparency and Increase Contrast, then confirm text remains legible and interactive controls remain distinguishable. Enable Reduce Motion and inspect palette presentation and settings transitions.
3. Resize the home and settings windows, move them between Retina and external displays, enter and leave full screen, hide and restore the application, and reopen settings repeatedly. Verify focus, traffic lights, configuration scrolling, and the Helm-inspired home layout.
4. Navigate home controls and settings with keyboard only, including Tab, Shift-Tab, arrow keys, and Return. Inspect VoiceOver names and selected states. Search home configuration and verify the visible controls remain editable. Confirm Command-K remains unavailable until a desktop is running.
5. Capture home, every settings pane, and, with a running desktop, the command palette with results and its empty state. Include the host OS, Xcode version, display scaling, appearance, and accessibility settings with the evidence.

## Real guest integration gates

Use a disposable **ARM64** Linux installation and a test folder containing nonsensitive files. Record the exact guest image source, checksum, kernel, desktop session, Omarchy build or adaptation, and guest integration package versions. Do not describe an x86-only Omarchy image as compatible with Apple's native ARM virtualization path.

| Area | Exercise and evidence |
| --- | --- |
| Installation | Complete the supported installation/import flow from an empty profile. Cancel download or import, interrupt it, retry it, reject an invalid image, and recover without damaging an existing disk. Confirm installation errors explain the next action. |
| Boot and storage | Reach the guest desktop after a cold boot. Create a file, shut down cleanly, reopen the application, and verify it survives. Check firmware/identity persistence. Reject missing or inaccessible disk files without replacing them. |
| Graphics | Verify guest display rendering, resize response, Retina scaling, full screen, text sharpness, and a typical browser/terminal workload. Record whether desktop rendering uses software acceleration; do not infer Linux GPU acceleration from native window rendering. |
| Keyboard and pointer | Test letters, modifiers, punctuation, arrows, function keys, copy/paste, non-US layout, held keys, key release when focus changes, pointer scrolling, and the documented host-shortcut escape route. Test capture enabled and disabled. |
| Running Command-K | While the desktop is running, open the palette from guest focus and verify an empty query offers commands. Search by title and resource keyword; confirm the filtered machine row visibly says Configure machine and opens Machine settings. Verify a nonmatching query, clearing search, arrow selection, Return, and Escape. After the guest stops, confirm Command-K is unavailable again. |
| Clipboard | With required guest support installed, copy distinct Unicode and multiline text in both directions. Disable sharing, verify isolation, restart the guest, and re-enable it. Check unsupported guest clipboard configurations produce truthful guidance. |
| Audio output | Play guest audio, change the host output device, mute/unmute, suspend/resume where supported, and confirm there is no feedback or continued playback after shutdown. |
| Microphone | Test not-yet-requested, allowed, denied, and later-revoked host permission with explicit human interaction. Enable input in the app, record inside the guest, and confirm disabling input stops delivery. Boot remains possible with microphone access denied. |
| Screen sharing | Test screen capture inside the guest's own compositor/browser when supported. Confirm rendering a VM does not trigger a request for host Screen Recording. Any future host-screen sharing feature requires its own explicit macOS permission flow. |
| Shared folder | Grant access through the system picker. Read from the guest; reject writes when read-only; enable writes and verify a test file. Relaunch the host app, rename/remove the folder, revoke access, and recover through reselection. |
| Network | Verify NAT internet access, DNS, offline recovery, and guest isolation assumptions. No bridge entitlement or privileged helper should be required for the default connection. |
| Resources | Test accepted CPU, memory, and disk bounds on both a small-memory and larger Apple silicon Mac. Confirm changes that need shutdown are explained and applied on the next boot. Handle insufficient disk space without an incomplete machine appearing ready. |
| Lifecycle | Exercise start, pause/resume if supported, graceful shutdown, shutdown failure, explicit forced stop, closing the window, quitting while running, host sleep/wake, and unexpected guest stop. Each leaves a truthful state and usable recovery action. |
| Sandbox | Run a signed sandboxed build from a fresh user profile. Confirm guest files remain inside app-owned storage and selected folders work through security-scoped access. Inspect the final entitlements and verify hardened runtime signing. |
| Distribution | Build Release for arm64 with deployment target macOS 26. Install the signed/notarized app on a second Mac and repeat onboarding, file selection, microphone denial, guest boot, and persistence. |

## Performance and reporting

Measure release builds on named hardware. Record time to the welcome screen, time to first guest desktop, steady idle host CPU/memory, guest memory allocation, palette latency, resizing responsiveness, and disk usage. Use Instruments to investigate sustained host work while the guest is stopped, main-thread stalls, and retained VM/display objects after shutdown. Repeat measurements with the same guest and resource settings so changes are comparable.

For each validation run, report the build identifier, hardware, host OS, guest versions, automated test counts, result-bundle location, native screenshots, failures, and any unexecuted integration gates. Keep untested hardware/guest behavior explicitly separate from verified host UI behavior. Release requires a successful real guest pass; a rendered welcome screen or mocked test launch is not sufficient.
