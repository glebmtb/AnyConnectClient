# AnyConnectClient

macOS menu bar client for AnyConnect-compatible VPN servers in local SOCKS5 mode.

The app runs `openconnect --script-tun` with `ocproxy`, manages one or more VPN profiles, and exposes each profile as its own local SOCKS5 endpoint. It intentionally does not enable system-wide VPN, Network Extension, PAC, or system proxy settings.

## Коротко по-русски

AnyConnectClient - это macOS tray-клиент для AnyConnect/OpenConnect, который поднимает каждый VPN-профиль как отдельный локальный SOCKS5 endpoint. Приложение не включает system-wide VPN и не меняет системные proxy-настройки.

`ThirdParty/` не хранится в GitHub-репозитории: исходники и локальные сборки OpenConnect/ocproxy должны лежать там только на машине сборки и игнорируются git. Реальные профили, пароли, servercert pin, cookie и smoke-test адреса тоже нельзя коммитить.

## Project Origin

This project was generated and iteratively developed with OpenAI Codex in collaboration with the repository owner. Codex assisted with architecture, Swift implementation, tests, release packaging, and publication audit; runtime decisions and local VPN verification were guided by the owner.

## Status

- Platform: macOS 14+, Apple Silicon.
- Language: Swift 6.
- VPN mode: AnyConnect via OpenConnect CLI and ocproxy.
- Proxy mode: local SOCKS5 per profile.
- Release signing: ad-hoc only. Developer ID signing and notarization are not configured yet.

## Features

- Menu bar connect/disconnect/reconnect controls.
- Multiple simultaneous profiles with unique local SOCKS ports.
- Auto-start per profile on app launch.
- Reconnect handling for transient drops and wake events.
- Connection history in the menu.
- Credential storage using Touch ID-protected vault by default.
- Explicit unsafe local credential storage mode for users who accept the risk.
- Server certificate pin capture and rotation-aware handling.
- Route import snapshot viewer for OpenConnect split routes.

## Repository Layout

```text
Apps/AnyConnectClient/           macOS menu bar app
Sources/VPNCore/                 UI-free domain models, validation, redaction
Sources/OpenConnectRuntime/      process runner, command builder, ocproxy lifecycle
Sources/AnyConnectClientSupport/ profile settings and credential stores
Tools/AnyConnectCredentialTool/  local diagnostics and migration helper
Scripts/                         release packaging, smoke helpers, icon generation
Assets/                          app icon source and .icns
ThirdParty/                      local ignored OpenConnect and ocproxy source/build trees
docs/                            architecture, decisions, release notes
```

## Build

```sh
swift build
swift test --filter VPNCoreTests
swift test --filter AnyConnectClientSupportTests
swift test --filter OpenConnectRuntimeTests
```

Run the app from SwiftPM during development:

```sh
swift run AnyConnectClientApp
```

For app icon and Activity Monitor integration, run the packaged `.app` bundle rather than the bare SwiftPM executable.

## Release Packaging

Release packaging expects local OpenConnect and ocproxy source/build trees at:

```text
ThirdParty/openconnect-9.21/openconnect
ThirdParty/ocproxy/ocproxy
```

The whole `ThirdParty/` directory is intentionally ignored by git. Put or build those dependencies locally, then package:

```sh
Scripts/package-release-app.sh 1.0.0 1
```

Output:

```text
build/release/AnyConnectClient-1.0.0-build1/AnyConnectClient.app
build/release/AnyConnectClient-1.0.0-build1/AnyConnectClient-1.0.0-build1-macos-arm64.zip
```

The packaging script copies `openconnect`, `ocproxy`, and required Homebrew dylibs into the app bundle, rewrites dynamic library paths to bundle-relative paths, removes non-portable rpaths, embeds `AppIcon.icns`, and ad-hoc signs the result.

## Configuration

Profiles are created in the app UI. Runtime settings are stored under:

```text
~/Library/Application Support/AnyConnectClient/
```

Secrets are stored in the app credential vault. Do not commit local profile files, credentials, VPN logs, cookies, server certificate pins, or real smoke-test targets.

## Smoke Checks

Smoke URLs are intentionally not hardcoded. If using `AnyConnectCredentialTool smoke`, provide optional checks through environment variables:

```sh
ANYCONNECTCLIENT_SMOKE_POSITIVE_URLS="<positive-url>" \
ANYCONNECTCLIENT_SMOKE_NEGATIVE_URLS="<negative-url>" \
swift run AnyConnectCredentialTool smoke
```

## Publication Audit

Before publishing the repository or a release artifact:

```sh
Scripts/audit-publication.sh
```

For deployment-specific private marker checks, pass a local regular expression through the environment. Do not commit those markers:

```sh
ANYCONNECTCLIENT_PRIVATE_MARKERS="<private-regex>" Scripts/audit-publication.sh
```

## Security

See [SECURITY.md](SECURITY.md).

## Third-Party Code

The public repository does not track OpenConnect or ocproxy source trees. Release builds use local ignored copies under `ThirdParty/`; those projects remain under their upstream licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

Project code outside `ThirdParty/` is source-available with all rights reserved unless a different license is added later. See [LICENSE](LICENSE).
