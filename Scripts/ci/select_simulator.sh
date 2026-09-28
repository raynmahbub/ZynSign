#!/usr/bin/env bash
#
# ZynSign CI — simulator selection.
#
# Prints the name of the first available iPhone simulator. CI images and
# Xcode releases drift — device names and runtimes appear and disappear —
# so no workflow hardcodes "iPhone 16" anymore; they resolve the device
# through this script instead (build.sh and the ci.yml test steps).
#
# If the runner has no iPhone simulator at all, the iOS runtime is
# downloaded once (per runner) and selection retried. The toolchain
# state is annotated so a failing run explains itself.
#
# Output: the device name on stdout.
# Exit:   1 when no iPhone simulator is available.
#
set -euo pipefail

first_iphone() {
    xcrun simctl list devices available 2>/dev/null \
        | sed -nE 's/^[[:space:]]*(iPhone[^()]*) \(.*$/\1/p' \
        | head -n 1 \
        | sed -E 's/[[:space:]]+$//'
}

announce() {
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        printf '::notice title=Simulator::%s\n' "$1"
    fi
    echo "$1" >&2
}

SIM="$(first_iphone || true)"
if [[ -n "${SIM}" ]]; then
    echo "${SIM}"
    exit 0
fi

announce "No available iPhone simulator on this runner."
xcrun simctl list runtimes 2>&1 | sed -n '1,8p' >&2 || true

announce "Downloading the iOS simulator runtime (one-time per runner)…"
xcodebuild -downloadPlatform iOS >&2 || true

SIM="$(first_iphone || true)"
if [[ -n "${SIM}" ]]; then
    echo "${SIM}"
    exit 0
fi

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    xcrun simctl list runtimes 2>/dev/null | sed -n '2,8p' \
        | while IFS= read -r line; do
            printf '::error title=Simulator::%s\n' "${line}"
        done || true
fi
echo "No iPhone simulator available after downloading the iOS runtime." >&2
exit 1
