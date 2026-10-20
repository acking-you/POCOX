#!/usr/bin/env bash
# Package an existing Flutter Linux bundle, including its native dependencies.
set -euo pipefail
if [[ $# != 3 ]]; then
  echo "Usage: $0 <flutter-bundle> <icon.png> <output.AppImage>" >&2
  exit 2
fi
bundle=$(realpath "$1")
icon=$(realpath "$2")
output=$(realpath -m "$3")
test -x "$bundle/pocket_codex"
test -f "$icon"
mkdir -p "$(dirname "$output")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

# Pin both versions and bytes. The runtime's upstream release is rolling;
# an upstream replacement must be reviewed instead of silently entering a build.
fetch() {
  curl --fail --location --retry 3 "$1" --output "$2"
  printf '%s  %s\n' "$3" "$2" | sha256sum --check --status
  chmod +x "$2"
}
fetch https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage \
  linuxdeploy.AppImage c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d
fetch https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/7a3fbc31a9e5075073ff8790f26effbac5f84453/linuxdeploy-plugin-gtk.sh \
  linuxdeploy-plugin-gtk.sh b0f4cbc684a0103a9651f0955b635eaea0096b3a66c0f5a2c2aa337960375171
fetch https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage \
  appimagetool.AppImage ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
fetch https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64 \
  runtime-x86_64 617aa77314d57c8b8e4fae9c3f0b35af7b30d5529cb69e98f64f92510ed98a46

mkdir -p AppDir/usr/bin AppDir/usr/share/applications
cp -a "$bundle/." AppDir/usr/bin/
cat > AppDir/usr/share/applications/pocket-codex.desktop <<'DESKTOP'
[Desktop Entry]
Name=POCOX
Comment=Access your coding agents and sessions from every device
Exec=pocket_codex
Icon=pocket-codex
Terminal=false
Type=Application
Categories=Development;Utility;
DESKTOP
convert "$icon" -resize 256x256 pocket-codex.png

# The web-auth plugin links WebKit even though authentication uses the system
# browser. Collect every ELF dependency (including Flutter plugins), not just
# the tray libraries. The GTK plugin also supplies schemas and loadable modules.
export APPIMAGE_EXTRACT_AND_RUN=1 NO_STRIP=1 DEPLOY_GTK_VERSION=3
./linuxdeploy.AppImage --appdir AppDir --plugin gtk \
  --desktop-file AppDir/usr/share/applications/pocket-codex.desktop \
  --icon-file pocket-codex.png

# Flutter's assets stay beside the executable. Source the GTK resource hook
# while retaining the Flutter bundle's lib/ and linuxdeploy's shared lib/.
cat > AppDir/AppRun <<'APPRUN'
#!/bin/bash
set -e
export APPDIR="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$APPDIR/usr/bin/lib:$APPDIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
for hook in "$APPDIR"/apprun-hooks/*.sh; do
  [ ! -f "$hook" ] || source "$hook"
done
exec "$APPDIR/usr/bin/pocket_codex" "$@"
APPRUN
chmod +x AppDir/AppRun
ARCH=x86_64 ./appimagetool.AppImage --runtime-file runtime-x86_64 AppDir "$output"
