#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/release-common.sh"

release_configure
[[ -n ${OMABOX_NOTARY_PROFILE:-} ]] || release_die 'Set OMABOX_NOTARY_PROFILE to an existing notarytool Keychain profile.'
release_notary_timeout=${OMABOX_NOTARY_TIMEOUT:-30m}
[[ $release_notary_timeout =~ ^[1-9][0-9]*[smh]?$ ]] || release_die 'OMABOX_NOTARY_TIMEOUT must be a duration such as 30m.'
release_notary_arguments=(--keychain-profile "$OMABOX_NOTARY_PROFILE")
if [[ -n ${OMABOX_NOTARY_KEYCHAIN_PATH:-} ]]; then
    release_notary_arguments+=(--keychain "$(release_absolute_path "$OMABOX_NOTARY_KEYCHAIN_PATH")")
fi
release_verify_app "$release_app"
python3 "$release_root/Scripts/verify-guest.py" "$release_app/Contents/Resources/Guest"
for release_license in LICENSE THIRD_PARTY_NOTICES.md LICENSES/ThirdParty-MIT.txt; do
    [[ -f "$release_root/$release_license" ]] || release_die "Missing distribution notice: $release_license"
done
release_claim_destination "$release_output"
mkdir "$release_output"
package_work=$(mktemp -d "$release_output/.staging.XXXXXX")
package_mount="$package_work/mount"
package_mounted=0
package_cleanup() {
    if [[ $package_mounted == 1 ]]; then
        if ! hdiutil detach "$package_mount" >/dev/null; then
            echo "Could not detach $package_mount; staging retained at $package_work" >&2
            printf '%s\n' "$package_mount" > "$release_output/STAGING_MOUNTED.txt"
            rmdir "$release_lock_path" 2>/dev/null || true
            return
        fi
    fi
    rm -rf "$package_work"
    rmdir "$release_lock_path" 2>/dev/null || true
}
trap package_cleanup EXIT

package_stage="$package_work/volume"
mkdir "$package_stage"
ditto --rsrc --extattr --acl "$release_app" "$package_stage/Omabox.app"
ln -s /Applications "$package_stage/Applications"
mkdir "$package_stage/Licenses"
cp "$release_root/LICENSE" "$package_stage/Licenses/Omabox-LICENSE.txt"
cp "$release_root/THIRD_PARTY_NOTICES.md" "$package_stage/Licenses/THIRD_PARTY_NOTICES.md"
cp "$release_root/LICENSES/ThirdParty-MIT.txt" "$package_stage/Licenses/ThirdParty-MIT.txt"
for release_notice in LICENSE.omarchy packages.lock.txt provenance.json guest-manifest.json build-spec.json metadata.json; do
    cp "$release_app/Contents/Resources/Guest/$release_notice" "$package_stage/Licenses/$release_notice"
done
if [[ -d "$release_root/Guest/virtio-sound-source" ]]; then
    ditto "$release_root/Guest/virtio-sound-source" "$package_stage/Licenses/virtio-sound-source"
fi
python3 - "$release_root" "$package_stage/Licenses" <<'PY'
from pathlib import Path
import json
import shutil
import sys
root, destination = map(Path, sys.argv[1:])
resolved = root / "Tuist/Package.resolved"
with resolved.open() as stream:
    pins = json.load(stream)["pins"]
shutil.copy2(resolved, destination / "Swift-Package.resolved")
for pin in pins:
    identity = pin["identity"]
    checkout = root / "Tuist/.build/checkouts" / identity
    notices = [path for path in checkout.iterdir() if path.is_file() and path.name.upper().startswith(("LICENSE", "NOTICE", "COPYING"))]
    if not notices:
        raise SystemExit(f"No license found for {identity}; run tuist install with the pinned package resolution.")
    package_destination = destination / "Swift Packages" / identity
    package_destination.mkdir(parents=True)
    for notice in notices:
        shutil.copy2(notice, package_destination / notice.name)
PY

package_submit() {
    local artifact=$1
    local label=$2
    local report="$release_output/$label-notarization.json"
    if ! xcrun notarytool submit "$artifact" "${release_notary_arguments[@]}" \
        --wait --timeout "$release_notary_timeout" --output-format json > "$report"; then
        echo "Notarization did not finish successfully; inspect $report before submitting again." >&2
        return 1
    fi
    python3 - "$report" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    report = json.load(stream)
if report.get("status") != "Accepted":
    raise SystemExit(f"Notarization was not accepted. Inspect {sys.argv[1]} and fetch the notarytool log for {report.get('id', 'the submission')}.")
PY
}

package_check_size() {
    python3 - "$1" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
size = path.stat().st_size
if size >= 2_147_483_648:
    raise SystemExit(f"{path.name} is {size:,} bytes; GitHub release assets must be smaller than 2 GiB. Do not publish this image.")
print(f"Compressed release image: {size:,} bytes")
PY
}

ditto -c -k --keepParent "$package_stage/Omabox.app" "$package_work/Omabox-notarization.zip"
package_submit "$package_work/Omabox-notarization.zip" app
rm "$package_work/Omabox-notarization.zip"
xcrun stapler staple "$package_stage/Omabox.app"
xcrun stapler validate "$package_stage/Omabox.app"
release_verify_app "$package_stage/Omabox.app"
spctl --assess --type execute --verbose=2 "$package_stage/Omabox.app"

package_dmg="$release_output/Omabox-$release_version-arm64.dmg"
hdiutil create -volname Omabox -fs APFS -srcfolder "$package_stage" \
    -format UDZO -imagekey zlib-level=9 "$package_dmg"
package_sign_arguments=(--sign "$release_identity" --timestamp)
if [[ -n ${release_keychain:-} ]]; then
    package_sign_arguments+=(--keychain "$release_keychain")
fi
codesign "${package_sign_arguments[@]}" "$package_dmg"
package_check_size "$package_dmg"
package_submit "$package_dmg" dmg
xcrun stapler staple "$package_dmg"
xcrun stapler validate "$package_dmg"
codesign --verify --strict --verbose=2 "$package_dmg"
hdiutil verify "$package_dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$package_dmg"
package_check_size "$package_dmg"

mkdir "$package_mount"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$package_mount" "$package_dmg"
package_mounted=1
release_verify_app "$package_mount/Omabox.app"
xcrun stapler validate "$package_mount/Omabox.app"
[[ $(readlink "$package_mount/Applications") == /Applications ]] || release_die 'The disk image is missing its Applications link.'
cmp "$release_root/LICENSE" "$package_mount/Licenses/Omabox-LICENSE.txt"
cmp "$release_root/THIRD_PARTY_NOTICES.md" "$package_mount/Licenses/THIRD_PARTY_NOTICES.md"
cmp "$release_root/LICENSES/ThirdParty-MIT.txt" "$package_mount/Licenses/ThirdParty-MIT.txt"
hdiutil detach "$package_mount"
package_mounted=0

python3 - "$package_dmg" "$release_output" "$release_version" "$release_build" "$release_team" <<'PY'
from pathlib import Path
import hashlib
import json
import sys
image, output = map(Path, sys.argv[1:3])
hasher = hashlib.sha256()
with image.open("rb") as stream:
    for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
        hasher.update(chunk)
digest = hasher.hexdigest()
with (output / "SHA256SUMS").open("x") as stream:
    stream.write(f"{digest}  {image.name}\n")
with (output / "app-notarization.json").open() as stream:
    app_notary = json.load(stream)
with (output / "dmg-notarization.json").open() as stream:
    dmg_notary = json.load(stream)
manifest = {
    "schemaVersion": 1,
    "version": sys.argv[3],
    "buildNumber": sys.argv[4],
    "teamID": sys.argv[5],
    "architecture": "arm64",
    "minimumSystemVersion": "26.0",
    "file": image.name,
    "byteCount": image.stat().st_size,
    "sha256": digest,
    "appNotarizationID": app_notary["id"],
    "dmgNotarizationID": dmg_notary["id"],
    "verified": True,
}
with (output / "release-manifest.json").open("x") as stream:
    json.dump(manifest, stream, indent=2)
    stream.write("\n")
PY
echo "$package_dmg"
