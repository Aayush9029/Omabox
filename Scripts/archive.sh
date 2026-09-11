#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/release-common.sh"

release_configure
release_claim_destination "$release_archive"
cd "$release_root"
python3 Scripts/verify-guest.py
command -v tuist >/dev/null || release_die 'Install the pinned Tuist version before archiving.'
tuist install
tuist generate --no-open
release_derived_data=$(release_absolute_path "${OMABOX_DERIVED_DATA_PATH:-build/DerivedData-Release}")
xcodebuild archive \
    -workspace "$release_root/Omabox.xcworkspace" \
    -scheme Omabox \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$release_archive" \
    -derivedDataPath "$release_derived_data" \
    "MARKETING_VERSION=$release_version" \
    "CURRENT_PROJECT_VERSION=$release_build" \
    "DEVELOPMENT_TEAM=$release_team" \
    "CODE_SIGN_IDENTITY=$release_identity" \
    "OTHER_CODE_SIGN_FLAGS=$release_signing_flags" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    ENABLE_HARDENED_RUNTIME=YES \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO
release_verify_app "$release_archive/Products/Applications/Omabox.app"
python3 Scripts/verify-guest.py "$release_archive/Products/Applications/Omabox.app/Contents/Resources/Guest"
echo "$release_archive"
