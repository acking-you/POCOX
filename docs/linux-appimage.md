# Linux AppImage packaging

The AppImage uses the Flutter Linux release bundle, including its plugins and
assets. `scripts/package_appimage.sh` collects ELF dependencies with linuxdeploy
and GTK schemas/modules with its GTK plugin. Tool versions and SHA-256 digests
are pinned in the script. A separate static AppImage runtime removes the old
runtime's dependency on the host's glibc and libfuse2. The application itself
still uses the host's glibc, with Ubuntu 22.04 as the tested baseline; this is
not a promise of compatibility with every Linux distribution.

`flutter_web_auth_2` uses our system-browser/loopback login path, but its native
WebView plugin still links WebKitGTK. v0.6.0 originally omitted that library and
failed before showing a window on systems without WebKit. Copying just the
Ayatana tray libraries did not cover the app's native dependency closure.
The unused `libdartjni.so` from `path_provider_android` is omitted: Linux uses
`path_provider_linux`, so a Java VM is not a runtime dependency of POCOX.

Both the regular release job and `.github/workflows/appimage.yml` use the same
packaging script. `scripts/test_appimage.sh` runs the resulting artifact as an
unprivileged user in a clean Ubuntu 22.04 desktop container, with no network,
FUSE, WebKit packages or build dependencies. It checks the executable/plugins
with `ldd`, then requires a visible POCOX window that stays running. The main
release job will not upload its Linux packages if this check fails.
Pull requests build their own Linux bundle before packaging, so changes to
native library names and executable names are checked against the same commit.
Manual repair requires an explicit release tag with `pocox-app-*` assets.

For a packaging-only repair of an existing release, run **AppImage packaging**
with the release tag. By default it produces only a tested workflow artifact.
With `publish=true` on `main`, it replaces that release's AppImage and refreshes
its signed update manifest. The input ZIP is verified against the release's
signed manifest before unpacking; the publication step verifies the current
manifest again and retains the release version, build, source commit and other
artifacts. The launcher icon comes from that signed source commit as well,
instead of the current checkout. The signing key remains in GitHub Actions secrets.

Keep `pocox-app-<tag>-linux-x86_64.AppImage`: existing installed updaters
select that suffix. AppImageHub's filename suggestions are advisory, so they do
not justify breaking the update contract. Once a repaired artifact is public,
the upstream repository owner can request `/retest` on the catalog PR.
