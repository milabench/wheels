#!/bin/bash
# Assert the wheels build OS is Ubuntu 22.04 and still within standard support.
#
# Standard security maintenance for Ubuntu 22.04 LTS ends May 2027:
#   https://ubuntu.com/about/release-cycle
#
# When this guard fires, bump CI runners/containers to a supported LTS and
# update UBUNTU_BUILD_VERSION / UBUNTU_BUILD_EOL below.
set -euo pipefail

UBUNTU_BUILD_VERSION="22.04"
# Last day of May 2027 (end of standard support month).
UBUNTU_BUILD_EOL="2027-05-31"

today="$(date -u +%Y-%m-%d)"
if [[ "${today}" > "${UBUNTU_BUILD_EOL}" ]]; then
    echo "::error::Ubuntu ${UBUNTU_BUILD_VERSION} standard support ended on ${UBUNTU_BUILD_EOL} (today: ${today} UTC)."
    echo "Update wheels CI to a supported Ubuntu LTS (runners, container-image default,"
    echo "and this script's UBUNTU_BUILD_VERSION / UBUNTU_BUILD_EOL)."
    exit 1
fi

if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" != "${UBUNTU_BUILD_VERSION}" ]; then
        echo "::error::Wheels CI expects Ubuntu ${UBUNTU_BUILD_VERSION}, found ${PRETTY_NAME:-$ID $VERSION_ID}."
        echo "Set workflow runners to ubuntu-22.04 / ubuntu-22.04-arm and container-image to ubuntu:22.04."
        exit 1
    fi
    echo "==> Build OS OK: ${PRETTY_NAME:-Ubuntu ${VERSION_ID}} (EOL ${UBUNTU_BUILD_EOL}, today ${today} UTC)"
else
    echo "==> Build OS EOL check OK (no /etc/os-release; EOL ${UBUNTU_BUILD_EOL}, today ${today} UTC)"
fi
