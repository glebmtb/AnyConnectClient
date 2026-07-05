# Security Policy

## Supported Versions

The current development baseline is `1.0.0`. Older snapshots are not supported.

## Reporting a Vulnerability

Do not open a public issue containing credentials, VPN endpoints, cookies, server certificate pins, logs with secrets, or private network details.

For now, report privately to the repository owner through the chosen private channel for the deployment. If this project becomes public for multiple users, add a dedicated security contact before accepting external reports.

## Secret Handling Rules

- Never commit real VPN credentials, cookies, OTP values, client keys, server certificate pins, or local profile files.
- Never paste real VPN endpoints or internal smoke-test URLs into issues, pull requests, screenshots, logs, or fixtures.
- Passwords are passed to OpenConnect through stdin, not process arguments.
- Runtime logs must go through redaction before display or persistence.
- `ThirdParty/` source code is vendored, but locally built binaries are ignored and must be rebuilt on the release machine.

## Known Release Limitation

Release bundles are currently ad-hoc signed. Gatekeeper-friendly distribution requires Developer ID signing and notarization.
