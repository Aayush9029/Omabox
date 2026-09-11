#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/release-common.sh"

release_configure
[[ -d $release_archive ]] || release_die "Archive not found: $release_archive"
release_claim_destination "$release_export"
release_archive_app="$release_archive/Products/Applications/Omabox.app"
release_verify_app "$release_archive_app"
python3 "$release_root/Scripts/verify-guest.py" "$release_archive_app/Contents/Resources/Guest"
release_options="$release_lock_path/ExportOptions.plist"
python3 - "$release_options" "$release_team" "$release_identity" <<'PY'
import plistlib
import sys
options = {
    "method": "developer-id",
    "destination": "export",
    "signingStyle": "manual",
    "signingCertificate": sys.argv[3],
    "teamID": sys.argv[2],
    "manageAppVersionAndBuildNumber": False,
    "stripSwiftSymbols": True,
}
with open(sys.argv[1], "xb") as stream:
    plistlib.dump(options, stream)
PY
trap 'rm -f "$release_options"; rmdir "$release_lock_path" 2>/dev/null || true' EXIT
xcodebuild -exportArchive \
    -archivePath "$release_archive" \
    -exportPath "$release_export" \
    -exportOptionsPlist "$release_options"
release_verify_app "$release_app"
python3 "$release_root/Scripts/verify-guest.py" "$release_app/Contents/Resources/Guest"
echo "$release_app"
