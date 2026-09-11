# Validation

Checked September 11, 2026: M4 Pro on macOS 27 beta for native interaction; macOS 26 for CI.

[Main CI](https://github.com/Aayush9029/Omabox/actions/runs/34643056766) passed for `238ff385`: **182 Swift cases and 218 Python checks**. Workflow lint and release-script syntax checks passed.

Native checks passed for Home/Settings synchronization, configuration editing, host-menu navigation, pause/resume, full screen, and actual guest resolution changes. Guest `0.4.0` passed boot, adaptive scaling, configuration reload, and SSH enable/disable. Hidden Settings measured zero CPU over 20 seconds; this was a limited observation.

[v0.1.0](https://github.com/Aayush9029/Omabox/releases/tag/v0.1.0) passed signing, app/DMG notarization, stapling, Gatekeeper, mounted-image checks, and a real guest import.

[v0.1.1](https://github.com/Aayush9029/Omabox/releases/tag/v0.1.1) published automatically after CI. Its [release workflow](https://github.com/Aayush9029/Omabox/actions/runs/34643604213) passed signing, notarization, artifact verification, publication, and credential cleanup.

README photos use build 10, a focused centered window, the actual wallpaper, and a five-second timer. JPEG copies reduce photo size by 94%.

Still unverified: the full XCUITest run (13 functions compile; beta runner timed out), physical audio, browser screen sharing, non-US keyboards, external displays, sleep/wake, visible GIF playback, another Mac, and a live guest on macOS 26.

[Testing](Testing.md) · [Releases](Release.md)
