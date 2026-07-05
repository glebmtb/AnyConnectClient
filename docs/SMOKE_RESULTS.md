# Smoke results

## 2026-07-05: CLI OpenConnect + ocproxy

Status:

- CLI smoke passed after correcting local profile data.
- Protocol: `anyconnect`.
- Mode: SOCKS5 via `openconnect --script-tun` + `ocproxy`.
- Local profile values and secret values were not printed.

Network/TLS:

- TCP 443 connection to the VPN server succeeds in the local environment.
- TLS negotiation succeeds.
- OpenConnect can generate a `servercert` pin when the server certificate is not trusted by the system CA.
- Pin values were detected, persisted, and reused without printing them.

Authentication:

- Explicit authgroup support is required.
- Authentication succeeds with valid local credentials.

SOCKS result:

- `ocproxy` starts and listens on the configured local SOCKS endpoint.
- Positive smoke URLs supplied by the local environment return HTTP 200 through SOCKS5h.
- Negative smoke URLs supplied by the local environment fail through SOCKS5h as expected.
- Cleanup closes OpenConnect and `ocproxy`; the SOCKS port is free after stop.

Reusable command shape:

```text
openconnect
  --protocol=anyconnect
  --user=<redacted>
  --authgroup=<redacted>
  --passwd-on-stdin
  --servercert=<redacted>
  --script-tun
  --script="<absolute ocproxy path> -D 127.0.0.1:<profile port> -k 30"
  --os=mac-intel
  <redacted server>
```

## 2026-07-05: DNS/FQDN smoke fix

Status:

- Root cause was local `NO_PROXY`/`no_proxy` environment, not VPN DNS.
- If an internal domain suffix is present in `NO_PROXY`, `curl` can bypass SOCKS and try local DNS.
- Correct smoke command uses `curl --noproxy "" --socks5-hostname 127.0.0.1:<port> ...`.

## 2026-07-05: credentials migration

Status:

- Credential migration completed without printing secret values.
- Runtime profile settings file: present.
- Password/servercert pin: present in the selected credential store.
- Legacy secret keys: absent after migration.

Runtime source of truth:

- non-secret profile settings: app settings JSON
- password/servercert pin: credential store
- legacy profile: import-only source, safe to delete after migration

## 2026-07-05: release packaging

Status:

- Release app bundle includes the app executable, `openconnect`, `ocproxy`, and required dylibs.
- Homebrew dylib load paths are rewritten to `@executable_path/../Frameworks`.
- App version: `1.0.0`.
- Build number: `1`.
