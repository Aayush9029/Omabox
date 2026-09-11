#!/bin/bash
set -euo pipefail

ci_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ci_root"

case "${1:-all}" in
    all)
        bash "$ci_root/Scripts/ci.sh" guest
        bash "$ci_root/Scripts/ci.sh" native
        ;;
    guest)
        python3 -B -m unittest discover -s Guest -p 'test_*.py' -v
        python3 -B Guest/overlay/usr/local/libexec/omabox-clipboard-agent.py --self-test
        python3 -B -m unittest discover -s Scripts/tests -p 'test_*.py' -v
        for guest_script in Guest/*.sh; do
            bash -n "$guest_script"
        done
        ;;
    native)
        if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
            echo 'Native CI requires an Apple silicon macOS runner.' >&2
            exit 1
        fi
        if [[ $(tuist version) != 4.207.0 ]]; then
            echo 'Native CI requires Tuist 4.207.0.' >&2
            exit 1
        fi
        ci_sdk_version=$(xcrun --sdk macosx --show-sdk-version)
        if (( ${ci_sdk_version%%.*} < 26 )); then
            echo 'Native CI requires the macOS 26 SDK or newer.' >&2
            exit 1
        fi

        mkdir -p build/ci
        ci_run_root=$(mktemp -d "$ci_root/build/ci/run.XXXXXX")
        xcodebuild -version | tee "$ci_run_root/toolchain.txt"
        xcrun swift --version | tee -a "$ci_run_root/toolchain.txt"
        ci_guest_directory=Omabox/Resources/Guest
        if [[ -L $ci_guest_directory ]]; then
            echo 'Refusing a symlink for the guest resource directory.' >&2
            exit 1
        elif [[ -d $ci_guest_directory ]]; then
            if [[ -f $ci_guest_directory/CI_ONLY_NOT_A_GUEST.txt ]]; then
                echo 'Using the existing CI-only resource fixture.'
            elif [[ -f $ci_guest_directory/metadata.json ]]; then
                echo 'Using the existing prepared guest resources.'
            else
                echo 'Existing guest resources have neither a prepared manifest nor a CI marker.' >&2
                exit 1
            fi
        else
            python3 Scripts/ci_guest_fixture.py
        fi
        tuist install
        tuist generate --no-open

        xcodebuild build-for-testing \
            -workspace Omabox.xcworkspace \
            -scheme Omabox \
            -configuration Debug \
            -destination 'platform=macOS,arch=arm64' \
            -derivedDataPath build/ci/DerivedData \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGN_IDENTITY=- \
            DEVELOPMENT_TEAM= \
            PROVISIONING_PROFILE_SPECIFIER= \
            2>&1 | tee "$ci_run_root/build.log"

        xcodebuild test-without-building \
            -workspace Omabox.xcworkspace \
            -scheme Omabox \
            -configuration Debug \
            -destination 'platform=macOS,arch=arm64' \
            -derivedDataPath build/ci/DerivedData \
            -resultBundlePath "$ci_run_root/UnitTests.xcresult" \
            -only-testing:OmaboxTests \
            -parallel-testing-enabled NO \
            2>&1 | tee "$ci_run_root/unit-tests.log"
        echo "Native CI results: $ci_run_root"
        ;;
    *)
        echo 'Usage: Scripts/ci.sh [all|guest|native]' >&2
        exit 2
        ;;
esac
