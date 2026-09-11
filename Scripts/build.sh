#!/bin/bash
set -euo pipefail
build_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$build_root"
if [[ ! -f Omabox/Resources/Guest/metadata.json ]]; then
    echo 'Prepare the guest first: ./Scripts/prepare-guest.sh' >&2
    exit 1
fi
tuist install
tuist generate --no-open
build_configuration=${OMABOX_CONFIGURATION:-Debug}
build_identity=${OMABOX_SIGNING_IDENTITY:--}
xcodebuild build \
    -workspace Omabox.xcworkspace \
    -scheme Omabox \
    -configuration "$build_configuration" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedData \
    CODE_SIGN_STYLE=Manual \
    "CODE_SIGN_IDENTITY=$build_identity"
echo "$build_root/build/DerivedData/Build/Products/$build_configuration/Omabox.app"
