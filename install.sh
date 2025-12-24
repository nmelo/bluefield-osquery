#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024 Nelson Melo
#
# Install BlueField-3 osquery security extension

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/local/bin"
OSQUERY_CONF_DIR="/etc/osquery"
CACHE_DIR="/var/cache"
CRON_DIR="/etc/cron.d"

echo "Installing BlueField-3 osquery security extension..."

# Check if running on BlueField
if [[ ! -d /sys/devices/platform/MLNXBF04:00 ]] && [[ ! -d /sys/devices/platform/MLNXBF03:00 ]]; then
    echo "Warning: BlueField sysfs not detected. This may not be a BlueField DPU."
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root" >&2
    exit 1
fi

# Check dependencies
echo "Checking dependencies..."
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 is required" >&2; exit 1; }
command -v osqueryi >/dev/null 2>&1 || { echo "Warning: osquery not found. Install osquery first." >&2; }

# Install scripts
echo "Installing scripts to ${INSTALL_DIR}..."
install -m 755 "${SCRIPT_DIR}/scripts/bf3_security_query" "${INSTALL_DIR}/"
install -m 755 "${SCRIPT_DIR}/scripts/bf3_security_update" "${INSTALL_DIR}/"

# Create osquery config directory if needed
mkdir -p "${OSQUERY_CONF_DIR}"

# Install osquery configuration
echo "Installing osquery configuration..."
if [[ -f "${OSQUERY_CONF_DIR}/osquery.conf" ]]; then
    echo "  Backing up existing osquery.conf to osquery.conf.bak"
    cp "${OSQUERY_CONF_DIR}/osquery.conf" "${OSQUERY_CONF_DIR}/osquery.conf.bak"
fi
install -m 644 "${SCRIPT_DIR}/config/osquery.conf" "${OSQUERY_CONF_DIR}/"

# Create cache directory
mkdir -p "${CACHE_DIR}"

# Install cron job
echo "Installing cron job..."
install -m 644 "${SCRIPT_DIR}/config/bf3-security.cron" "${CRON_DIR}/bf3-security"

# Run initial update
echo "Generating initial security data..."
"${INSTALL_DIR}/bf3_security_update"

# Verify installation
echo ""
echo "Verifying installation..."
if osqueryi "SELECT lifecycle_state, hardware_rot_status FROM bf3_security;" 2>/dev/null | grep -q "lifecycle_state"; then
    echo "Success! bf3_security table is available."
    echo ""
    echo "Example queries:"
    echo "  osqueryi \"SELECT * FROM bf3_security;\""
    echo "  osqueryi \"SELECT lifecycle_state, hardware_rot_status, uefi_secure_boot FROM bf3_security;\""
else
    echo "Warning: Could not verify bf3_security table. Check osquery configuration."
fi

echo ""
echo "Installation complete!"
