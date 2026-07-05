# Third-Party Notices

This project vendors third-party source code so the VPN runtime can be studied, built, and packaged locally.

## OpenConnect

- Path: `ThirdParty/openconnect-9.21/`
- Upstream: OpenConnect VPN client
- License file in this repository: `ThirdParty/openconnect-9.21/COPYING.LGPL`
- Notes: Release packaging may bundle a locally built `openconnect` executable. Built binaries are not committed to git.

## ocproxy

- Path: `ThirdParty/ocproxy/`
- Upstream: ocproxy
- License file in this repository: `ThirdParty/ocproxy/LICENSE`
- Notes: Release packaging may bundle a locally built `ocproxy` executable. Built binaries are not committed to git.

## lwIP inside ocproxy

- Path: `ThirdParty/ocproxy/lwip/`
- License file in this repository: `ThirdParty/ocproxy/lwip/COPYING`

## Generated App Icon

- Source asset: `Assets/AppIconSource.png`
- Generated artifacts: `Assets/AppIcon.png`, `Assets/AppIcon.icns`
- Project ownership: covered by the root `LICENSE` unless replaced with another explicit license.

## Distribution Notes

If you distribute packaged `.app` or `.zip` artifacts, include the relevant third-party license files and notices. The release package embeds executable binaries and dynamic libraries built from local dependencies; verify their licenses before public binary distribution.
