# Contributing

This project is maintained as a small, security-sensitive macOS utility.

## Rules

- Keep core modules UI-free.
- Do not assemble shell command strings in UI code.
- Keep each VPN profile isolated with its own SOCKS endpoint.
- Do not commit local VPN profiles, credentials, real endpoints, logs, generated cookies, server certificate pins, or screenshots containing private infrastructure.
- Treat `ThirdParty/` as vendored upstream code. Do not patch it directly without documenting the reason.
- Prefer small vertical changes with tests.

## Checks

```sh
swift test --filter VPNCoreTests
swift test --filter AnyConnectClientSupportTests
swift test --filter OpenConnectRuntimeTests
Scripts/audit-publication.sh
```

## Release

Release packaging requires locally built `openconnect` and `ocproxy` binaries. They are intentionally ignored by git.
