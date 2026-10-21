# App updates

POCOX checks GitHub Releases of `acking-you/POCOX` quietly and, when the user
asks, installs the newer release in one step. The design follows the updater
of the sibling project proxy-everything (a signed release manifest, per-platform
installers), with the logic in Rust (`crates/pocket-codex-bridge/src/engine/updates`)
and only the app's own part in Flutter (`apps/flutter/lib/src/updates`).

## What the user sees

- Nothing at startup. The first check runs 20 seconds after the app starts
  (after the first frame), then at most every six hours, also across
  restarts. It fetches only the newest release's manifest and signature.
- When a newer release appears, one toast offers it, once per version
  (**Update**, or **Release page** where nothing can be installed). It goes by
  itself; there is no dialog.
- **Settings › Updates** shows the running version and what the last check
  found, with **Check now**, or **Update and restart** / **Update** /
  **Download** / **Release page** depending on the platform. The button shows
  its own progress (downloading with a percentage, verifying, restarting).
  Cancel stops a download. Failures name their cause, with the underlying
  error behind the info mark.

## Application network proxy

**Settings › Application network proxy** is available on phones and desktops.
Enter an `http://`, `https://`, `socks5://` or `socks5h://` URL, optionally with
`username:password@` authentication. For example, `http://127.0.0.1:7890` or
`socks5://127.0.0.1:1080`. On a phone, `127.0.0.1` means that phone; a proxy
running on a computer needs that computer's reachable address instead.

The private `[network].proxy` setting in the app's `config.toml` applies to
release manifests, signatures and package downloads (including redirects),
POCOX account/backend requests, GitHub avatars and site favicons. SOCKS5
resolves destination names through the proxy. Explicit proxies take precedence
over environment variables and bypass loopback destinations. An unavailable
proxy fails the request; it never falls back to a direct connection.

Save affects new operations without a restart. An existing transfer keeps its
client. Clearing the field restores the previous default: proxy environment
variables such as `HTTPS_PROXY` apply, but native OS proxy settings are not
read. Proxy credentials are masked in the editor and omitted from summaries
and debug output; the app's config remains private (0600 on Unix).

This setting does not configure relay TCP transports, hosted harnesses, the
Responses API service's upstream proxy, or pages opened in the system browser.
Their existing network configuration remains authoritative. Automatic checks
still fetch only release metadata; package downloading starts when the user
chooses Update. Signature and package verification remain mandatory.

## Trust

The release workflow's last job (`manifest` in `.github/workflows/release.yml`)
downloads every asset of the release, lists each file's size and SHA-256 in
`release-manifest.json`, and signs those exact bytes with an Ed25519 key
(`scripts/release_manifest.py`). The private key lives only in the repository
secret `UPDATE_SIGNING_KEY` and the maintainer's backup; the public key is
compiled into the app (`manifest::PUBLIC_KEY`) and kept in
`scripts/update_signing_key.pub.pem` for the workflow's own check.

The app:

1. fetches `releases/latest/download/release-manifest.json`, then the
   signature from the release the manifest names (`releases/download/v<version>/…`),
   so a release published in between cannot pair one manifest with another's
   signature;
2. accepts the manifest only if the signature verifies (ring, Ed25519) and
   every asset name is a plain file name;
3. downloads only the file meant for this installation, failing as soon as
   it grows past the listed size, and keeps it only if its size and SHA-256
   match;
4. on macOS, additionally requires the bundle inside the disk image to pass
   `codesign --verify --deep --strict`, carry the release team's identifier
   (`5T7QB722FM`), pass Gatekeeper (`spctl --assess`: Developer ID signed and
   notarized), and be `io.github.ackingyou.pocketCodex` at exactly the
   manifest's version.

Android's package installer additionally refuses a package signed with another
certificate.

## Per platform

| Installation | File | How it applies |
|---|---|---|
| macOS app bundle | `…-macos-arm64.dmg` / `…-macos-x64.dmg` (this build's architecture) | Staged out of the disk image and verified; the app quits through its normal path (hosted services stop first); a helper swaps the bundle and reopens it. Restores the old bundle if the swap fails. A bundle the user cannot replace (another owner, App Translocation) opens the disk image instead. |
| Windows, installed | `…-windows-x64-setup.exe` | The app quits; a helper runs the installer silently (elevated: UAC asks) and reopens the app. |
| Windows, portable | `…-windows-x64.zip` | Saved to Downloads and shown in Explorer. |
| Linux AppImage | `…-linux-x86_64.AppImage` | The app quits; a helper replaces the AppImage file (`$APPIMAGE`) and reopens it. |
| Linux `.deb` | `…-linux-amd64.deb` | Opened in the desktop's package installer; restart POCOX after it finishes. |
| Linux portable | `…-linux-x64.zip` | Saved to Downloads and shown. |
| Android | `…-android-<abi>.apk` (this build's ABI) | Handed to the system installer, which asks the user. The first time, Android asks to allow POCOX to install apps. |
| iOS (sideloaded) | none | An app cannot install itself: **Release page** opens the release. |

A release without a file for this installation (a platform's job failed, an
architecture not built) is offered through its release page.

If the app cannot quit (a hosted service did not stop), the quit banner says
why; the helper waits up to two minutes for the process to exit and otherwise
gives up without touching anything. **Retry** applies the same verified
download again.

The CLI is not updated by the app: run the install script again, which updates
`pocox` in place (`scripts/install.sh`, `scripts/install.ps1`).

## Testing a release copy

Development builds never replace themselves: they stop after verification
("Verified. Development builds do not replace themselves."), unless one of
these variables is set on purpose (release builds ignore them all):

- `POCOX_UPDATE_FEED`: a directory URL holding a copy of a release
  (`release-manifest.json`, its `.sig`, the files);
- `POCOX_UPDATE_PUBLIC_KEY`: the raw base64 Ed25519 key that copy is signed
  with;
- `POCOX_UPDATE_INSTALLED_VERSION`: the version the app pretends to run.

`scripts/release_manifest.py collect|sign|verify` builds such a copy with a
test key.

## Limits

- Native macOS/Windows proxy settings and the system browser are outside the
  application proxy setting. Configure an explicit URL when needed.
- Verified on macOS only (see the PR for the run). Windows, Linux and Android
  paths compile in the release workflow and are covered by unit tests of the
  shared logic, not by a run on those systems.
