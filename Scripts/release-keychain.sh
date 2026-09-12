#!/bin/bash
set -euo pipefail
umask 077

[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted && ${RUNNER_OS:-} == macOS ]] || {
    echo 'This helper only manages credentials on a GitHub-hosted macOS runner.' >&2
    exit 1
}
[[ ${GITHUB_RUN_ID:-} =~ ^[0-9]+$ && ${GITHUB_RUN_ATTEMPT:-} =~ ^[0-9]+$ && -d ${RUNNER_TEMP:-} ]] || exit 1
credential_root="$RUNNER_TEMP/Omabox-credentials-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
credential_keychain="$credential_root/release.keychain-db"

case "${1:-}" in
    setup)
        : "${APPLE_CERTIFICATE_P12:?Missing Developer ID certificate.}"
        : "${APPLE_CERTIFICATE_PASSWORD:?Missing Developer ID certificate password.}"
        : "${APPLE_API_KEY_P8:?Missing notarization private key.}"
        : "${APPLE_API_KEY_ID:?Missing notarization key identifier.}"
        : "${APPLE_API_ISSUER_ID:?Missing notarization issuer identifier.}"
        [[ ! -e "$credential_root" ]] || { echo 'Release credentials already exist for this attempt.' >&2; exit 1; }
        mkdir "$credential_root"
        trap 'rm -f "$credential_root/certificate.p12" "$credential_root/notary.p8"' EXIT
        python3 - "$credential_root" <<'PY'
import base64
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

root = Path(sys.argv[1])
search_list = subprocess.check_output(['/usr/bin/security', 'list-keychains', '-d', 'user'], text=True)
(root / 'search-list.json').write_text(json.dumps(shlex.split(search_list)))
for variable, filename in [('APPLE_CERTIFICATE_P12', 'certificate.p12'), ('APPLE_API_KEY_P8', 'notary.p8')]:
    decoded = base64.b64decode(''.join(os.environ[variable].split()), validate=True)
    if not decoded:
        raise SystemExit('A release credential is empty.')
    (root / filename).write_bytes(decoded)
PY
        credential_password=$(python3 -c 'import secrets; print(secrets.token_urlsafe(40))')
        printf '::add-mask::%s\n' "$credential_password"
        security create-keychain -p "$credential_password" "$credential_keychain"
        security set-keychain-settings -lut 21600 "$credential_keychain"
        security unlock-keychain -p "$credential_password" "$credential_keychain"
        security import "$credential_root/certificate.p12" -P "$APPLE_CERTIFICATE_PASSWORD" -t cert -f pkcs12 \
            -k "$credential_keychain" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
        security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
            -k "$credential_password" "$credential_keychain" >/dev/null
        python3 - "$credential_root/search-list.json" "$credential_keychain" <<'PY'
import json
import subprocess
import sys
with open(sys.argv[1]) as stream:
    previous = json.load(stream)
subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', sys.argv[2], *previous], check=True)
PY
        credential_identity=$(security find-identity -v -p codesigning "$credential_keychain" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)
        [[ -n $credential_identity ]] || { echo 'No Developer ID Application identity was imported.' >&2; exit 1; }
        credential_profile="omabox-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
        xcrun notarytool store-credentials "$credential_profile" \
            --key "$credential_root/notary.p8" --key-id "$APPLE_API_KEY_ID" \
            --issuer "$APPLE_API_ISSUER_ID" --keychain "$credential_keychain" >/dev/null
        printf 'OMABOX_KEYCHAIN_PATH=%s\nOMABOX_NOTARY_KEYCHAIN_PATH=%s\nOMABOX_NOTARY_PROFILE=%s\nOMABOX_SIGNING_IDENTITY=%s\n' \
            "$credential_keychain" "$credential_keychain" "$credential_profile" "$credential_identity" >> "$GITHUB_ENV"
        ;;
    cleanup)
        [[ -d "$credential_root" ]] || exit 0
        credential_status=0
        if [[ -f "$credential_root/search-list.json" ]]; then
            python3 - "$credential_root/search-list.json" <<'PY' || credential_status=1
import json
import subprocess
import sys
with open(sys.argv[1]) as stream:
    previous = json.load(stream)
subprocess.run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *previous], check=True)
PY
        fi
        if [[ -f "$credential_keychain" ]]; then
            security delete-keychain "$credential_keychain" || credential_status=1
        fi
        rm -f "$credential_root/certificate.p12" "$credential_root/notary.p8" "$credential_root/search-list.json"
        rmdir "$credential_root" 2>/dev/null || true
        exit "$credential_status"
        ;;
    *)
        echo 'Usage: release-keychain.sh setup|cleanup' >&2
        exit 2
        ;;
esac
