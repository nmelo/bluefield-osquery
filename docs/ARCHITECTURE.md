# Architecture and Design Decisions

This document explains the architecture of the BlueField-3 osquery security extension, the tradeoffs considered, and the rationale behind key design decisions.

## Overview

The extension exposes NVIDIA BlueField-3 DPU hardware root of trust data as a SQL-queryable osquery table. The challenge is bridging two very different interfaces:

1. **Source**: Linux sysfs, vendor CLI tools (mlxconfig, bfver), and EFI variables
2. **Target**: osquery's ATC (Automatic Table Construction) which expects a SQLite database

## Data Flow Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              osquery daemon                                  │
│                                    │                                         │
│                         ATC Engine reads SQLite                              │
│                                    │                                         │
│                         /var/cache/bf3_security.db                           │
└─────────────────────────────────────────────────────────────────────────────┘
                                     ▲
                                     │ atomic rename
                                     │
┌─────────────────────────────────────────────────────────────────────────────┐
│                          bf3_security_update                                 │
│                                    │                                         │
│    1. Create temp files with restrictive permissions (600)                   │
│    2. Run bf3_security_query → JSON                                          │
│    3. Validate columns against allowlist                                     │
│    4. Convert to SQLite with parameterized queries                           │
│    5. Atomic mv to final location                                            │
└─────────────────────────────────────────────────────────────────────────────┘
                                     ▲
                                     │
┌─────────────────────────────────────────────────────────────────────────────┐
│                          bf3_security_query                                  │
│                                    │                                         │
│         ┌──────────────┬───────────┼───────────┬──────────────┐             │
│         ▼              ▼           ▼           ▼              ▼             │
│    ┌─────────┐   ┌──────────┐ ┌─────────┐ ┌─────────┐   ┌──────────┐        │
│    │  sysfs  │   │ mlxconfig│ │  bfver  │ │EFI vars │   │ InfiniBand│       │
│    │MLNXBF04 │   │ (root)   │ │ (root)  │ │SecureBoot│  │  sysfs   │        │
│    └─────────┘   └──────────┘ └─────────┘ └─────────┘   └──────────┘        │
│         │              │           │           │              │             │
│    lifecycle     crypto_policy  ATF/UEFI   secure_boot    fw_version        │
│    fuse_state    dpa_auth       versions                                    │
│    uuid/sn/sku                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
┌─────────────────────────────────────────────────────────────────────────────┐
│                     BlueField-3 Hardware                                     │
│                                                                              │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐             │
│  │    ERoT    │  │    ATF     │  │    UEFI    │  │  ConnectX  │             │
│  │ (HW Fuses) │  │  (BL1/2)   │  │            │  │     FW     │             │
│  │            │  │            │  │            │  │            │             │
│  │ lifecycle  │  │ measured   │  │ secure     │  │ crypto     │             │
│  │ state      │  │ boot       │  │ boot       │  │ offload    │             │
│  └────────────┘  └────────────┘  └────────────┘  └────────────┘             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Design Decisions

### 1. Why ATC Instead of a Native osquery Extension?

**Decision**: Use osquery's Automatic Table Construction (ATC) with a SQLite database.

**Alternatives Considered**:
- Native C++ osquery extension
- Python osquery extension via Thrift
- Custom osquery table plugin

**Tradeoffs**:

| Approach | Pros | Cons |
|----------|------|------|
| **ATC + SQLite** | No compilation, works with stock osquery, easy to debug | Requires cron job, up to 5-minute data staleness |
| **C++ Extension** | Real-time data, native performance | Requires C++ build chain, osquery SDK, harder to maintain |
| **Python Extension** | Real-time data, easier than C++ | Requires osquery-python, Thrift dependency |

**Rationale**: ATC is the pragmatic choice for a specialized hardware platform. The DPU's security posture changes infrequently (only on firmware updates or reconfiguration), so 5-minute staleness is acceptable. The simplicity of deployment outweighs the benefits of real-time queries. The cron job runs as root, providing access to mlxconfig and bfver which require elevated privileges.

### 2. Why Two Scripts Instead of One?

**Decision**: Separate `bf3_security_query` (Python) and `bf3_security_update` (Bash wrapper).

**Rationale**:
- **bf3_security_query**: Pure data collection, outputs JSON, can be run standalone for debugging
- **bf3_security_update**: Orchestration layer handling file permissions, atomic updates, SQLite conversion

This separation enables:
- Testing the query script independently
- Using the JSON output for other integrations (Prometheus, SIEM)
- Different security contexts (sysfs data works without root; mlxconfig/bfver require root for full output)

### 3. Why Not Use shell=True in subprocess?

**Decision**: Use argument lists instead of shell strings.

**Before** (vulnerable):
```python
run_cmd(f"mlxconfig -d {mst_device} q | grep CRYPTO")  # shell=True
```

**After** (secure):
```python
run_cmd(["mlxconfig", "-d", mst_device, "q"])  # No shell
```

**Rationale**: Even though we control the MST device path, defense in depth requires eliminating shell injection vectors. The device path comes from directory listing (`/dev/mst/*`), which could theoretically be influenced by an attacker with local access. By validating against a strict regex pattern AND using argument lists, we have two layers of protection.

### 4. Why Allowlist Columns?

**Decision**: Both scripts maintain an explicit allowlist of valid column names.

```python
ALLOWED_COLUMNS = frozenset({
    "lifecycle_state",
    "secure_boot_fuse_state",
    # ... etc
})
```

**Threat Model**: A malicious actor with write access to `/sys/devices/platform/MLNXBF04:00/` could potentially create a file with a name that, when used as a column name in SQL, causes injection. While this requires root access (making the attack mostly moot), the allowlist provides defense in depth.

**Tradeoff**: Adding new columns requires updating both scripts. This duplication is intentional:
1. New security attributes are rare (firmware updates only)
2. Explicit is better than implicit for security tooling
3. A shared module would be a single point of compromise; duplication limits blast radius

### 5. Why Atomic File Updates?

**Decision**: Write to temp files, then atomically rename.

```bash
install -m 600 /dev/null "${JSON_FILE}.tmp"
"${QUERY_SCRIPT}" > "${JSON_FILE}.tmp"
mv "${JSON_FILE}.tmp" "${JSON_FILE}"
```

**Rationale**:
- **Atomicity**: osquery never sees a partially-written file
- **Permissions**: Files are created with 600 before any data is written
- **Crash safety**: If the script fails, the old data remains intact

### 6. Why Validate MST Device Paths?

**Decision**: Validate MST device paths against a strict regex and verify they're character devices.

```python
MST_DEVICE_PATTERN = re.compile(r"^/dev/mst/mt\d+_pciconf\d+(\.\d+)?$")

if not MST_DEVICE_PATTERN.match(device_path):
    continue
if not device.is_char_device():
    continue
```

**Threat Model**: The `/dev/mst/` directory is managed by the MST kernel driver, but we validate anyway because:
1. The path is passed to `mlxconfig` which runs with elevated privileges
2. Symlink attacks could redirect to arbitrary paths
3. Defense in depth is cheap here

### 7. Why Support BlueField-2?

**Decision**: Include BlueField-2 sysfs path (`MLNXBF03:00`) even though this is a BF3-focused tool.

**Rationale**: Minimal additional code, and organizations often have mixed fleets. The sysfs interface is similar enough that most attributes work on both platforms.

## Security Model

### Trust Boundaries

```
┌─────────────────────────────────────────────────────────────┐
│                    Trusted Execution                         │
│                                                              │
│  ┌──────────────────┐    ┌──────────────────┐               │
│  │  bf3_security_   │    │  bf3_security_   │               │
│  │     query        │    │     update       │               │
│  │  (runs as root)  │    │  (runs as root)  │               │
│  └────────┬─────────┘    └────────┬─────────┘               │
│           │                       │                          │
└───────────┼───────────────────────┼──────────────────────────┘
            │                       │
┌───────────▼───────────────────────▼──────────────────────────┐
│                    Semi-Trusted Inputs                        │
│                                                              │
│  ┌──────────────────┐    ┌──────────────────┐               │
│  │     sysfs        │    │    mlxconfig     │               │
│  │ (kernel-managed) │    │  (vendor tool)   │               │
│  └──────────────────┘    └──────────────────┘               │
│                                                              │
│  These are trusted in normal operation but validated anyway  │
│  because: (1) defense in depth, (2) easier auditing         │
└──────────────────────────────────────────────────────────────┘
```

### What We Protect Against

| Threat | Mitigation |
|--------|------------|
| Command injection via MST path | Regex validation + no shell |
| SQL injection via column names | Allowlist + parameterized queries |
| Race conditions on output files | Atomic rename |
| Information disclosure via file permissions | 600 permissions before write |
| Partial reads by osquery | Atomic file replacement |

### What We Don't Protect Against

- **Root compromise**: If an attacker has root, they can modify the scripts directly
- **Kernel compromise**: sysfs data comes from the kernel; a compromised kernel can lie
- **Hardware attacks**: The tool reports what the hardware says; it cannot detect hardware tampering

## Performance Considerations

### Update Frequency

The cron job runs every 5 minutes. This is a tradeoff:

- **More frequent**: Higher load, minimal benefit (security posture rarely changes)
- **Less frequent**: Stale data during firmware updates

5 minutes is chosen because:
1. Firmware updates are rare and planned
2. Security monitoring typically aggregates over longer periods
3. The query completes in <1 second

### Resource Usage

- **CPU**: Negligible (<0.1s per run)
- **Memory**: Python process peaks at ~15MB
- **Disk**: ~4KB JSON, ~8KB SQLite
- **I/O**: Reads ~20 small sysfs files

## Future Considerations

### SPDM/DICE Attestation

The BlueField-3 supports SPDM (Security Protocol and Data Model) for remote attestation, but this requires:
1. MCTP network configuration or BMC access
2. Certificate chain verification
3. Nonce-based freshness

This extension focuses on local posture; remote attestation would be a separate tool.

### Host-Side Queries

Currently runs on the DPU ARM cores. A future enhancement could query from the host x86 side via:
- PCIe config space
- Redfish API to BMC
- rshim interface

### osquery Native Extension

If real-time queries become important, the codebase is structured to enable migration:
- `get_security_info()` is a pure function returning a dict
- Column definitions are explicit
- No global state

## Testing

### Manual Testing

```bash
# Run query directly (sysfs data only)
./scripts/bf3_security_query

# Run with root for full output (includes mlxconfig/bfver data)
sudo ./scripts/bf3_security_query

# Run with debug logging
sudo BF3_DEBUG=1 ./scripts/bf3_security_query

# Verify osquery table
sudo osqueryi "SELECT * FROM bf3_security;"
```

### What to Verify

1. **On BlueField-3**: All columns populated, `hardware_rot_status` is "Enforced"
2. **On BlueField-2**: Most columns work, some may be empty
3. **On non-BlueField**: Script exits cleanly with empty/missing data

## References

- [osquery ATC Documentation](https://osquery.readthedocs.io/en/stable/deployment/configuration/#auto-table-construction)
- [BlueField-3 Software Documentation](https://docs.nvidia.com/networking/display/bluefield3swv4131)
- [DICE Architecture](https://trustedcomputinggroup.org/resource/dice-layering-architecture/)
- [SPDM Specification](https://www.dmtf.org/standards/spdm)
