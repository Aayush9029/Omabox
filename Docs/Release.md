# Release Omabox

Omabox ships as a Developer ID signed and notarized Apple silicon DMG for macOS 26 or later. App Sandbox and Hardened Runtime remain enabled in distribution builds.

## Automatic releases

Pushing to `main` starts [CI](../.github/workflows/ci.yml). Once its guest checks and native build/tests pass, [Release](../.github/workflows/release.yml) packages that exact commit on a hosted macOS runner. The workflow checks that the commit is still the current `main` before publishing.

Each release uses the next available patch version. After `v0.1.0`, the next release is `v0.1.1`. Build numbers start above the initial build 10. Releases run serially, and retrying an already published commit does not publish another version. An abandoned automation draft reserves its version; a newer commit skips it without changing the draft. The workflow can also be started manually to retry the current `main` after its CI succeeds.

The workflow archives the app, exports it with Xcode's Developer ID method, notarizes and staples the app, then creates, signs, notarizes, and staples the DMG. The release remains a draft until the verified DMG, `SHA256SUMS`, and `release-manifest.json` are attached. The README download button follows the latest published release.

Configure these repository secrets and variables in GitHub Actions settings:

| Name | Type | Value |
| --- | --- | --- |
| `APPLE_CERTIFICATE_P12` | Secret | Base64-encoded Developer ID Application certificate and private key, exported with an empty P12 password. |
| `APPLE_API_KEY_P8` | Secret | Base64-encoded App Store Connect API private key. |
| `APPLE_API_KEY_ID` | Secret | API key identifier. |
| `APPLE_API_ISSUER_ID` | Secret | API issuer identifier. |
| `OMABOX_TEAM_ID` | Variable | Apple development team identifier. |
| `OMABOX_SIGNING_IDENTITY` | Variable | Full Developer ID Application identity name. |

Credentials are imported into a temporary runner Keychain. Cleanup restores the previous Keychain search list and removes the temporary credentials. Pull request checks do not receive signing secrets.

## Prepared Linux guest

Hosted Apple silicon runners do not support the nested virtualization needed to prepare the Linux factory. The release workflow imports the already prepared guest from a pinned Omabox DMG instead. [GitHub runner limitations](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

[Guest/prepared-release.json](../Guest/prepared-release.json) pins the DMG URL, byte count, SHA-256, guest metadata and payload hashes, and a hash of the guest build inputs. The importer verifies the download before mounting it read-only, extracts only the guest resources, and verifies them again before making them available to the build. It refuses to overwrite an existing guest directory.

Changes to the guest overlay, source pins, or preparation scripts invalidate the build-input hash. To update the factory:

1. Prepare and test the new guest on a physical Apple silicon Mac using the local commands below.
2. Package and publish a verified release containing that factory.
3. Update the prepared-release manifest with that immutable DMG's URL, final byte count and SHA-256, and the new guest metadata. Obtain the build-input hash with `python3 Scripts/fetch-release-guest.py --print-source-hash`.
4. Test the importer in a clean checkout before pushing the updated pin.

Keep the pinned release asset available; future app releases depend on it. The workflow removes intermediate guest, archive, and export copies as their consumers finish to limit runner disk usage.

## Local archive and package

Use a physical Apple silicon Mac with macOS 26 or later, Xcode selected through `xcode-select`, the repository's pinned Tuist version, and Python 3.9 or later. Allow at least 35 GB of free space. Install the Developer ID identity and create a `notarytool` Keychain profile before packaging.

```sh
export OMABOX_VERSION=0.1.0
export OMABOX_BUILD_NUMBER=10
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

For unchanged guest inputs, a clean checkout can run `python3 Scripts/fetch-release-guest.py` instead of preparing a new factory. `--image /path/to/release.dmg` uses a local DMG with the same pinned integrity checks.

Output defaults to `build/Archives/Omabox-VERSION-BUILD.xcarchive`, `build/Export/Omabox-VERSION-BUILD`, and `build/Release/Omabox-VERSION-BUILD`. Override these with `OMABOX_ARCHIVE_PATH`, `OMABOX_EXPORT_PATH`, and `OMABOX_RELEASE_PATH`. Destinations must not already exist; each script reserves its output with a sibling lock directory. Failed partial outputs remain available for inspection.

An explicit signing Keychain can be set with `OMABOX_KEYCHAIN_PATH`; use `OMABOX_NOTARY_KEYCHAIN_PATH` for the notarization profile's Keychain. `OMABOX_NOTARY_TIMEOUT` defaults to `30m` per submission. A timeout does not cancel Apple's processing: preserve the submission ID and inspect it with `xcrun notarytool info` or `log` before retrying. [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

## Distribution checks

The scripts reject synthetic CI guest fixtures, invalid guest hashes, incorrect provenance, unexpected architectures, missing sandbox entitlements, and signing exceptions such as debugger access or disabled library validation. They verify the selected Developer ID team, secure signing timestamp, bundle version, and minimum macOS version.

Packaging validates both stapled tickets and Gatekeeper acceptance, mounts the finished DMG read-only, and checks its app, Applications link, and bundled licenses. The release manifest is written only after these checks pass. The DMG must remain below 2 GiB for GitHub release hosting. [GitHub release limits](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)

The DMG includes Omabox's license, third-party notices, guest package inventory and provenance, supplied Virtio sound source, and resolved Swift dependency licenses. See [third-party notices](../THIRD_PARTY_NOTICES.md). Local scripts retain the archive, export, and final release output. If volume detachment fails, inspect `STAGING_MOUNTED.txt` and detach that volume before removing its staging directory.
