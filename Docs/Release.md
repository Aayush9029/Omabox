# Release Omabox

The release pipeline produces a Developer ID signed, notarized, arm64-only disk image for macOS 26 and later. The release scripts use an Xcode archive and Developer ID export. They verify the factory guest, the app’s signature and entitlements, and the final mounted image. They do not create or publish a GitHub release themselves.

## Release Mac

Use a physical Apple silicon Mac with macOS 26 or later, Xcode selected through `xcode-select`, the repository’s pinned Tuist version, and Python 3.9 or later. Guest preparation and validation require Apple Virtualization support. Keep sufficient free space for the factory, archive, exported app, staging app, and compressed images; a clean release may need 35 GB or more.

Install the Developer ID Application certificate and its private key on the release Mac ahead of time. The selected Keychain must be unlocked and allow the signing tools to use that identity. Create a `notarytool` Keychain profile separately. The scripts do not import certificates, export keys, or store credentials in the repository.

## Configuration

Set these environment variables for all three commands:

| Variable | Required | Meaning |
| --- | --- | --- |
| `OMABOX_VERSION` | Yes | Numeric app version, such as `0.1.0`. Release tags use three components. |
| `OMABOX_BUILD_NUMBER` | Yes | Positive integer build number. CI uses `github.run_number`. |
| `OMABOX_SIGNING_IDENTITY` | Yes | Full Developer ID Application certificate name or SHA-1 fingerprint. |
| `OMABOX_TEAM_ID` | No | Apple development team; defaults to `4538W4A79B`. |
| `OMABOX_KEYCHAIN_PATH` | No | Signing Keychain path when an explicit Keychain is needed. Export also requires the identity to be available in the user’s Keychain search list. |
| `OMABOX_NOTARY_PROFILE` | Packaging | Existing `notarytool` Keychain profile name. |
| `OMABOX_NOTARY_KEYCHAIN_PATH` | No | Keychain containing that notarization profile. |
| `OMABOX_NOTARY_TIMEOUT` | No | Maximum wait per notarization submission, default `30m`. |
| `OMABOX_ARCHIVE_PATH` | No | Archive destination; defaults to `build/Archives/Omabox-VERSION-BUILD.xcarchive`. |
| `OMABOX_EXPORT_PATH` | No | Export destination directory; defaults to `build/Export/Omabox-VERSION-BUILD`. |
| `OMABOX_RELEASE_PATH` | No | Package destination directory; defaults to `build/Release/Omabox-VERSION-BUILD`. |
| `OMABOX_DERIVED_DATA_PATH` | No | Archive build cache; defaults to `build/DerivedData-Release`. |

Relative paths are resolved against the repository root. Destinations must not already exist. Each command reserves its destination with a sibling `.lock` directory so simultaneous invocations cannot write the same output. Successful output and failed partial output are preserved for inspection; choose a new destination or remove an inspected failed attempt before retrying. A process killed without cleanup may leave its reservation behind.

## Local archive and package

```sh
export OMABOX_VERSION=0.1.0
export OMABOX_BUILD_NUMBER=1
export OMABOX_TEAM_ID=4538W4A79B
export OMABOX_SIGNING_IDENTITY='Developer ID Application: Aayush Pokharel (4538W4A79B)'
export OMABOX_NOTARY_PROFILE=omabox-notary

./Scripts/prepare-guest.sh
./Scripts/ci.sh
./Scripts/check-guest.sh
./Scripts/archive.sh
./Scripts/export.sh
./Scripts/package-release.sh
```

`archive.sh` runs `tuist install`, generates the workspace, and archives the Release scheme for `generic/platform=macOS`. Version, build, signing team, identity, timestamp, hardened runtime, and arm64 architecture are explicit. It verifies both the source guest and the archived copy. The Xcode scheme also uses Release for Product → Archive.

`export.sh` verifies the archive and exports it with Xcode’s `developer-id` method, manual signing, and local export destination. It then verifies the exported app and its guest. The workflow does not recursively re-sign an exported bundle.

`package-release.sh` copies the exported app to temporary staging, creates a ZIP with `ditto`, submits it to Apple, checks for `Accepted`, and staples the app. It builds a compressed APFS/UDZO disk image with an Applications link and a Licenses directory, signs and notarizes that image, and staples it. The script validates both tickets, runs strict code-signature and Gatekeeper checks, mounts the image read-only, and verifies the app and installation link inside it. Staging and the app notarization ZIP are removed when the command exits.

The final directory contains `Omabox-VERSION-arm64.dmg`, `SHA256SUMS`, `release-manifest.json`, and the two notarization result files. The manifest is written only after all checks pass. The DMG must remain below 2 GiB, including its final stapled ticket, to qualify as a GitHub release asset. [GitHub release limits](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)

Notarization uploads occur only in `package-release.sh`. A timeout does not cancel Apple’s processing. Preserve the submission ID from the JSON report and inspect it with `xcrun notarytool info` or `log` before submitting again. [Apple’s notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

## Checks that block distribution

`Scripts/verify-guest.py` rejects the `CI_ONLY_NOT_A_GUEST.txt` marker, tiny fixture images, missing files, symbolic links, invalid ARM64/kernel/initramfs/ext4 headers, mismatched provenance, and incorrect manifest sizes or SHA-256 hashes. The synthetic guest used by hosted CI cannot pass release verification. A real prepared factory image is required.

App verification requires the expected bundle identifier and version/build, a macOS 26 deployment target, only arm64 Mach-O binaries, the selected Developer ID team, a secure signing timestamp, hardened runtime, sandboxing, and the expected virtualization and device entitlements. Debugger access, JIT, unsigned executable memory, and disabled library validation are rejected.

The disk image includes Omabox’s license, third-party notices, guest package inventory and provenance, the supplied Virtio sound source, and the resolved Swift dependency licenses. Package-specific source distribution obligations still apply to the Linux guest. See [third-party notices](../THIRD_PARTY_NOTICES.md) and [Apple API choices](AppleAPIs.md).

## GitHub Actions

[The release workflow](../.github/workflows/release.yml) runs on `v*` tag pushes or a manual dispatch naming an existing tag. Its hosted validation job requires `vMAJOR.MINOR.PATCH` and confirms that the tagged commit belongs to `main` before it can reach signing credentials.

The archive job runs in the GitHub `release` environment on a trusted, physical runner with labels `self-hosted`, `macOS`, `ARM64`, and `omabox-release`. Configure environment variables matching the table above for the preinstalled signing identity and notarization profile. The workflow supplies version, build number, and unique output directories for each attempt. Pull requests use hosted CI and do not run on this signing machine.

The release Mac prepares and tests the real guest, runs the three scripts, and uploads the compressed archive and release image as temporary Actions artifacts with seven-day retention. The hosted publish job checks `SHA256SUMS` and creates the tagged GitHub release. Existing releases are not overwritten by the scripts or workflow. Keep the signing runner dedicated to trusted release work and use the environment’s protection rules to control who can start it.

Local scripts retain the archive, export, and final release output. The CI job should preserve bounded notarization reports before removing its unique temporary archive, export, ZIP, and release directories after artifact upload, including on failure; the archive cache may be retained for subsequent builds. Packaging staging lives inside the unique release directory and is removed on ordinary exit. If detaching a verification volume fails, `STAGING_MOUNTED.txt` records its path; detach that volume before removing its staging directory. No app launch or notarization submission is needed to test the scripts’ guest validation and shell preflight paths.
