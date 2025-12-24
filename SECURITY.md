# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| latest  | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly:

1. **Do not** open a public GitHub issue for security vulnerabilities
2. Email the maintainer directly at the address listed in the git commit history
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

You can expect:
- Acknowledgment within 48 hours
- Status update within 7 days
- Credit in the fix commit (unless you prefer anonymity)

## Security Considerations

This tool runs with root privileges via cron to access hardware security state. The codebase has been hardened against:

- Command injection (subprocess uses argument lists, not shell)
- SQL injection (column allowlist validation)
- Path traversal (strict regex validation of device paths)
- Race conditions (atomic file operations)
- Information disclosure (restrictive file permissions)

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full security model and threat analysis.
