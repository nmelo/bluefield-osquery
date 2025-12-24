# BlueField-3 osquery Security Extension

Query NVIDIA BlueField-3 DPU hardware root of trust data via osquery.

This extension exposes the BlueField-3's DICE/ERoT (Device Identifier Composition Engine / Embedded Root of Trust) security posture as a SQL-queryable osquery table.

## Features

- **Hardware Root of Trust Status**: Lifecycle state, secure boot fuse status, and derived security posture
- **UEFI Secure Boot**: Whether the ARM boot chain is cryptographically verified
- **Firmware Versions**: ATF (ARM Trusted Firmware), UEFI, BSP, and ConnectX firmware versions
- **Crypto Policy**: Hardware cryptographic accelerator configuration
- **Device Identity**: UUID, serial number, SKU, and MAC address

## Requirements

- NVIDIA BlueField-3 DPU (BlueField-2 partially supported)
- Ubuntu 22.04+ or compatible Linux on the DPU ARM cores
- osquery 5.x+
- Python 3.8+
- NVIDIA DOCA/MLNX_OFED drivers (for full functionality)

## Installation

```bash
git clone https://github.com/nmelo/bluefield-osquery.git
cd bluefield-osquery
sudo ./install.sh
```

## Usage

### Query Security Posture

```sql
SELECT lifecycle_state, hardware_rot_status, uefi_secure_boot
FROM bf3_security;
```

Output:
```
+-----------------+---------------------+------------------+
| lifecycle_state | hardware_rot_status | uefi_secure_boot |
+-----------------+---------------------+------------------+
| GA Secured      | Enforced            | Enabled          |
+-----------------+---------------------+------------------+
```

### Query Device Identity

```sql
SELECT device_uuid, serial_number, fw_version
FROM bf3_security;
```

Output:
```
+----------------------------------+---------------+-------------+
| device_uuid                      | serial_number | fw_version  |
+----------------------------------+---------------+-------------+
| 8ae8c17e7aa8f01180008c913af47cca | MT2542X00000  | 32.43.1014  |
+----------------------------------+---------------+-------------+
```

### Query Full Security State

```sql
SELECT * FROM bf3_security;
```

Output (using `osqueryi --line`):
```
       lifecycle_state = GA Secured
secure_boot_fuse_state = 3:Incomplete 2:Incomplete 1:Incomplete 0:Used
           device_uuid = 8ae8c17e7aa8f01180008c913af47cca
         serial_number = MT2542X00000
                   sku = 900-9D3B6-00CC-EA0
      uefi_secure_boot = Enabled
           atf_version = 4.13.1-0-g5fcb148df
          uefi_version = 4.13.1-14-g8a01157b7f
           bsp_version = 4.13.1.13827
            fw_version = 32.43.1014
         crypto_policy = UNRESTRICTED(1)
    dpa_authentication = False(0)
   hardware_rot_status = Enforced
```

## Table Schema

| Column | Description |
|--------|-------------|
| `lifecycle_state` | DPU security lifecycle: "GA Secured", "Development", etc. |
| `secure_boot_fuse_state` | Status of hardware security fuse banks |
| `hardware_rot_status` | Derived status: "Enforced", "Configured", "Development", "Unknown" |
| `uefi_secure_boot` | UEFI Secure Boot: "Enabled", "Disabled", "Unknown" |
| `device_uuid` | Hardware UUID from fuses |
| `serial_number` | Device serial number |
| `sku` | Stock keeping unit identifier |
| `opn` | Orderable part number |
| `revision` | Hardware revision |
| `oob_mac` | Out-of-band management MAC address |
| `atf_version` | ARM Trusted Firmware version (secure boot stages) |
| `uefi_version` | UEFI firmware version |
| `bsp_version` | Board Support Package version |
| `fw_version` | ConnectX firmware version |
| `crypto_policy` | Hardware crypto policy: "UNRESTRICTED", "RESTRICTED", etc. |
| `dpa_authentication` | DPA program signing enforcement |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      osquery daemon                          │
│                           │                                  │
│                    ATC (Auto Table                           │
│                     Construction)                            │
│                           │                                  │
│                   /var/cache/bf3_security.db                 │
└─────────────────────────────────────────────────────────────┘
                            ▲
                            │ (cron every 5 min)
                            │
┌─────────────────────────────────────────────────────────────┐
│                  bf3_security_update                         │
│                           │                                  │
│                  bf3_security_query                          │
│                     /     │     \                            │
│                    /      │      \                           │
│              sysfs    mlxconfig   bfver                      │
│         (MLNXBF04:00)  (mst)    (DOCA)                       │
└─────────────────────────────────────────────────────────────┘
                            │
┌─────────────────────────────────────────────────────────────┐
│              BlueField-3 Hardware                            │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐     │
│  │   ERoT   │  │   ATF    │  │   UEFI   │  │ ConnectX │     │
│  │ (SecCtl) │  │ (BL1/2)  │  │          │  │    FW    │     │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘     │
└─────────────────────────────────────────────────────────────┘
```

## Security Considerations

- The query script reads from sysfs (no credentials required)
- `mlxconfig` requires root access to query hardware settings
- Cache contains device identifiers (UUID, serial, MAC) and security posture; files are root-readable only
- Debug logging can be enabled with `BF3_DEBUG=1` environment variable

## BlueField-3 Security Architecture

The BlueField-3 DPU implements a hardware root of trust using:

- **ERoT (Embedded Root of Trust)**: Dedicated security controller with its own firmware
- **DICE (Device Identifier Composition Engine)**: TCG standard for hardware-based device identity
- **ARM Trusted Firmware (ATF)**: Secure world firmware providing the verified boot chain
- **Secure Boot Fuses**: One-time programmable fuses that lock the device into production mode

When `lifecycle_state` is "GA Secured" and `hardware_rot_status` is "Enforced", the DPU has:
- Burned production security fuses
- Locked boot chain to signed firmware only
- Hardware-backed device identity

## Troubleshooting

### Table shows empty values

Ensure you're running on the BlueField ARM cores, not the host x86 system:
```bash
uname -m  # Should show aarch64
```

### mlxconfig values missing

The MST driver may not be loaded:
```bash
sudo mst start
```

### osquery doesn't see the table

Restart osqueryd after installation:
```bash
sudo systemctl restart osqueryd
```

## License

Apache License 2.0

## Contributing

Contributions welcome! Please open an issue or pull request.

## Author

Nelson Melo
