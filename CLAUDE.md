# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

osquery extension that exposes NVIDIA BlueField-3 DPU hardware root of trust data as SQL-queryable tables. Runs on the BlueField ARM cores (aarch64), not the host x86 system.

## Commands

```bash
# Install on a BlueField DPU (requires root, run on aarch64)
sudo ./install.sh

# Manual query (outputs JSON)
./scripts/bf3_security_query

# Update the osquery ATC cache manually
sudo /usr/local/bin/bf3_security_update

# Test the osquery table
osqueryi "SELECT * FROM bf3_security;"

# Enable debug logging
BF3_DEBUG=1 ./scripts/bf3_security_query
```

## Architecture

```
cron (5min) -> bf3_security_update -> bf3_security_query -> JSON
                     |
                     v
              /var/cache/bf3_security.db (SQLite)
                     |
                     v
              osquery ATC (Auto Table Construction) -> bf3_security table
```

Data sources queried by `bf3_security_query`:
- **sysfs** (`/sys/devices/platform/MLNXBF04:00`): Primary source, always available on ARM. Provides lifecycle state, fuse status, device identity.
- **mlxconfig**: Requires MST driver (`mst start`). Provides crypto policy, DPA authentication.
- **bfver**: DOCA utility for ATF/UEFI/BSP versions.
- **EFI vars**: UEFI Secure Boot status from `/sys/firmware/efi/efivars/`.

## Key Files

| File | Purpose |
|------|---------|
| `scripts/bf3_security_query` | Python script that collects security data from sysfs/mlxconfig/bfver |
| `scripts/bf3_security_update` | Bash wrapper that runs query and converts JSON to SQLite for ATC |
| `config/osquery.conf` | osquery config defining the `bf3_security` ATC table |
| `config/bf3-security.cron` | Cron job running update every 5 minutes |
| `install.sh` | Installs scripts to `/usr/local/bin`, config to `/etc/osquery`, cron to `/etc/cron.d` |

## Development Notes

- BlueField-3 uses `MLNXBF04:00`, BlueField-2 uses `MLNXBF03:00` in sysfs paths
- The `hardware_rot_status` field is derived from `lifecycle_state` and `secure_boot_fuse_state`
- ATC reads from a SQLite DB file, not directly from the Python script
- Testing requires actual BlueField hardware or mocking the sysfs paths
