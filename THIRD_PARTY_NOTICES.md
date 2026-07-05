# Third-Party Notices

This project uses third-party OpenConnect and ocproxy source/build trees locally, but does not track them in the public repository. Put those dependencies under `ThirdParty/` on the release machine before packaging.

## OpenConnect

- Local path: `ThirdParty/openconnect-9.21/`
- Upstream: OpenConnect VPN client
- License file in the local source tree: `ThirdParty/openconnect-9.21/COPYING.LGPL`
- Notes: Release packaging may bundle a locally built `openconnect` executable. Third-party source and built binaries are not committed to git.

## ocproxy

- Local path: `ThirdParty/ocproxy/`
- Upstream: ocproxy
- License file in the local source tree: `ThirdParty/ocproxy/LICENSE`
- Notes: Release packaging may bundle a locally built `ocproxy` executable. Third-party source and built binaries are not committed to git.

## lwIP inside ocproxy

- Local path: `ThirdParty/ocproxy/lwip/`
- License file in the local source tree: `ThirdParty/ocproxy/lwip/COPYING`

## Generated App Icon

- Source asset: `Assets/AppIconSource.png`
- Generated artifacts: `Assets/AppIcon.png`, `Assets/AppIcon.icns`
- Project ownership: covered by the root `LICENSE` unless replaced with another explicit license.

## Distribution Notes

If you distribute packaged `.app` or `.zip` artifacts, include the relevant third-party license files and notices. The release package embeds executable binaries and dynamic libraries built from local dependencies; verify their licenses before public binary distribution.
