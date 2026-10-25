# App updates

POCOX checks GitHub Releases of `acking-you/POCOX` quietly and, when the user
asks, installs the newer release in one step. The design follows the updater
of the sibling project proxy-everything (a signed release manifest, per-platform
installers), with the logic in Rust (`crates/pocox-bridge/src/engine/updates`)
and only the app's own part in Flutter (`apps/flutter/lib/src/updates`).
Flutter renders the engine's state and does only what the app must: quit, the
Android installer channel, opening the release page.

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

**Settings › Application network proxy** is available on phones and desktops,
with three modes:

- **System** (the default): the proxy environment variables when set
  (`HTTPS_PROXY`, then `ALL_PROXY`, then `HTTP_PROXY`, with `NO_PROXY`),
  otherwise this computer's own setting: Windows' proxy settings (the
  `Internet Settings` registry values that proxy tools such as Clash set,
  with their bypass list; a per-protocol `ProxyServer` uses its HTTPS entry,
  then HTTP, then SOCKS) or macOS' network proxies (HTTPS, then HTTP, then
  SOCKS). It is read again for every client and every time the editor opens,
  which shows what it found. Automatic configuration scripts (PAC) are not
  evaluated; Linux and phones offer only the environment.
- **None**: requests connect directly, ignoring the environment and the
  system.
- **Custom**: an `http://`, `https://`, `socks5://` or `socks5h://` URL,
  optionally with `username:password@` authentication, for example
  `http://127.0.0.1:7890` or `socks5://127.0.0.1:1080`. On a phone,
  `127.0.0.1` means that phone; a proxy running on a computer needs that
  computer's reachable address instead.

The private `[network]` section of the app's `config.toml` holds `mode`
(`system`, `direct` or `custom`) and the custom `proxy` URL, which is kept
while another mode is chosen. A configuration saved before modes existed has
no `mode`: a saved `proxy` keeps working as **Custom**, and none means
**System** (until 0.7.5 that default read only the environment variables).
The setting applies to release manifests, signatures and package downloads
(including redirects), POCOX account/backend requests, GitHub avatars and site
favicons; every such client is built by `engine::network`, which reads the
system's proxy itself, so other HTTP clients of the app keep their own
behaviour. SOCKS5 resolves destination names through the proxy. Loopback
destinations always connect directly. An unavailable proxy fails the request;
it never falls back to a direct connection.

Save affects new operations without a restart. An existing transfer keeps its
client. Proxy credentials are masked in the editor and omitted from summaries
(the system's proxy is shown without them) and debug output; the app's config
remains private (0600 on Unix).

This setting does not configure relay TCP transports, hosted harnesses' own
requests, the Responses API service's upstream proxy, or pages opened in the
system browser. Their existing network configuration remains authoritative.
Checking and updating a computer's harnesses does use it: version lookups go
through the app's client, and installers get it in their environment only
([harness updates](harness-updates.md#network-proxy)). Automatic checks
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
   notarized), and be `io.github.ackingyou.pocox` at exactly the
   manifest's version.

Android's package installer additionally refuses a package signed with another
certificate.

## Per platform

| Installation | File | How it applies |
|---|---|---|
| macOS app bundle | `…-macos-arm64.dmg` / `…-macos-x64.dmg` (this build's architecture) | Staged out of the disk image and verified; the app quits through its normal path (hosted services stop first); a helper swaps the bundle and reopens it. Restores the old bundle if the swap fails. A bundle the user cannot replace (another owner, App Translocation) opens the disk image instead. |
| Windows, installed | `…-windows-x64-setup.exe` | A helper acknowledges startup before the app quits, runs the installer silently in the existing installation directory (elevated: UAC asks), and reopens the app. |
| Windows, portable | `…-windows-x64.zip` | Saved to Downloads and shown in Explorer. |
| Linux AppImage | `…-linux-x86_64.AppImage` | The app quits; a helper replaces the AppImage file (`$APPIMAGE`) and reopens it. |
| Linux `.deb` | `…-linux-amd64.deb` | Opened in the desktop's package installer; restart POCOX after it finishes. |
| Linux portable | `…-linux-x64.zip` | Saved to Downloads and shown. |
| Android | `…-android-<abi>.apk` (this build's ABI) | Handed to the system installer, which asks the user. The first time, Android asks to allow POCOX to install apps. |
| iOS (sideloaded) | none | An app cannot install itself: **Release page** opens the release. |

Android release packages are signed with a persistent release key since
v0.2.4. An older debug-signed installation cannot be updated to them: save its
settings, remove it, then install.

A release without a file for this installation (a platform's job failed, an
architecture not built) is offered through its release page.

If the app cannot quit (a hosted service did not stop), the quit banner says
why; the helper waits up to two minutes for the process to exit and otherwise
gives up without touching anything. **Retry** applies the same verified
download again.

On Windows, failure to start the helper keeps the app open. The helper uses
`CREATE_NO_WINDOW` and a new process group, without `DETACHED_PROCESS`: with
the latter, Windows PowerShell can exit successfully without executing its
script. A per-download lock prevents concurrent helpers from running the same
installer. Installer failure or UAC cancellation reopens the existing app and
retains the verified package. Each attempt leaves `helper.log` and, once the
installer runs, `installer.log` in `updates/work/<version>-<time>/handoff-<id>`
under the app support directory. A subsequent download clears this directory.

The Windows release/profile GUI never attaches to the launcher's console;
closing a shell or updater console cannot terminate it. Only debug builds
attach for Flutter diagnostics. The helper reopens the app without creating a
console and passes `/NORESTARTAPPLICATIONS` to Inno Setup so only the helper
owns the restart. POCOX does not install a task that reopens it after Quit;
external scheduled watchdogs must be disabled separately if they do so.

Windows installations of 0.7.0 and 0.7.1 contain the broken helper launch. They
need one manual installation of 0.7.2 or later from the release page; an old
client cannot acquire the updater fix through its own broken handoff.

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
- Windows CI runs Windows PowerShell subprocess tests for helper startup,
  acknowledgement failures, concurrent handoffs, waiting for app exit,
  successful installation, installer failure and reopening. These tests use
  temporary installers/apps and replace only the interactive UAC boundary;
  they do not validate an elevated installation into Program Files.
- Native Windows CI closes an owned launcher's console and verifies that a GUI
  using the release runner's console policy survives. It also exercises the
  Codex launcher through a batch shim and nested PowerShell command, checking
  that the command executes without a console window and retains its output.
- macOS has been exercised with a release build. Linux and Android paths
  compile in the release workflow and have shared-logic tests, but have not
  been exercised with their native installers.

## Naming baseline

The fresh-install baseline uses `pocox-app-*` artifacts and `pocox` application
identifiers. Earlier installations and data are not migrated. Both release
packaging and the updater select the new names; no legacy asset fallback exists.
Android uses the existing release signing key. `POCOX_ANDROID_KEY_ALIAS` (a
repository variable forwarded to Gradle) selects its keystore entry, defaulting
to `pocox` when unset or empty. A signing alias is independent of the application
ID; renaming the app does not require replacing its private key.
Release repair workflows verify the source manifest and reject older or mixed
artifact naming before uploading anything. Publish a new release for the new
baseline; do not retrofit an old release and replace its signed asset inventory.
