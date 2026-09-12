# Release

Releases are signed, notarized Apple silicon DMGs for macOS 26+.

## Automatic releases

Push to `main`. After [CI](../.github/workflows/ci.yml) passes, [Release](../.github/workflows/release.yml) publishes that commit's DMG, checksums, and manifest.

Patch versions advance automatically. Published commits are skipped. Manual dispatch retries tested `main`; newer commits stop stale publication.

| Setting | Type | Value |
| --- | --- | --- |
| `APPLE_CERTIFICATE_P12` | Secret | Base64 Developer ID certificate/private key. |
| `APPLE_CERTIFICATE_PASSWORD` | Secret | P12 password. |
| `APPLE_API_KEY_P8` | Secret | Base64 App Store Connect API private key. |
| `APPLE_API_KEY_ID` | Secret | API key ID. |
| `APPLE_API_ISSUER_ID` | Secret | API issuer ID. |
| `OMABOX_TEAM_ID` | Variable | `6Q29HJZ4AG` |

The release job reads the signing identity from the imported certificate. Temporary signing credentials are removed afterward.

## Local packaging

Requires Apple silicon, macOS 26+, Xcode, Tuist 4.207.0, Python 3.9+, and 35 GB free. Install a Developer ID identity and `notarytool` profile. Choose an unused version/build:

```sh
export OMABOX_VERSION=0.2.0 OMABOX_BUILD_NUMBER=20
export OMABOX_TEAM_ID=6Q29HJZ4AG
export OMABOX_SIGNING_IDENTITY='Developer ID Application: Optimal Life Technologies, Inc (6Q29HJZ4AG)'
export OMABOX_NOTARY_PROFILE=omabox-notary
python3 Scripts/fetch-release-guest.py
bash Scripts/archive.sh
bash Scripts/export.sh
bash Scripts/package-release.sh
```

Use a clean guest destination. Outputs under `build/` are never overwritten. After a notarization timeout, inspect the recorded submission before resubmitting.

## Update the bundled guest

1. Run `bash Scripts/prepare-guest.sh`, [tests](Testing.md), and `bash Scripts/check-guest.sh` on a physical Mac.
2. Package and publish the guest.
3. Update [prepared-release.json](../Guest/prepared-release.json) with its immutable URL, size, hashes, and metadata. Obtain the source hash with `python3 Scripts/fetch-release-guest.py --print-source-hash`.
4. Verify a clean import. Keep the pinned release available.

[Validation](Validation.md) · [Third-party notices](../THIRD_PARTY_NOTICES.md)
