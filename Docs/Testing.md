# Testing Omabox

Use Apple silicon, macOS 26+, Xcode with the macOS 26 SDK or newer, and Tuist 4.207.0.

## Automated tests

```sh
bash Scripts/ci.sh
```

Add `guest` for Python checks only or `native` for Swift tests only. These checks do not boot Linux.

Run UI tests on an unlocked Mac with no other automation:

```sh
tuist install
tuist generate --no-open
xcodebuild test -workspace Omabox.xcworkspace -scheme Omabox \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -only-testing:OmaboxUITests -parallel-testing-enabled NO \
  -resultBundlePath /tmp/Omabox-UI-tests.xcresult
```

Use a new result-bundle path each run. UI tests use isolated preferences and a simulated VM. Test flags have no effect in Release builds.

## Live checks

Use a disposable guest and the [guest QA runner](../Scripts/QA/README.md). Check:

- Installation, restart, saved files, and recovery after failure.
- Home/Settings synchronization and both configuration editors.
- Host-menu search, arrows, Return, pause/resume, and keyboard release.
- Resolution presets, automatic scale, full screen, and custom overrides.
- Clipboard, shared folders, SSH enable/disable, and revoked permissions.
- Audio, screen sharing, sleep/wake, external displays, and non-US keyboards.
- Appearance, accessibility, and animations stopping when hidden.

Record the build, host/guest versions, timings, resource use, and failures in [Validation](Validation.md). Keep untested behavior explicit; simulated tests cannot verify a working desktop or physical audio.
