#!/usr/bin/env bash
# Runs inside test_appimage.sh's clean, offline desktop container.
set -euo pipefail
unset LD_LIBRARY_PATH
# Also inspect every plugin, not just the executable: dlopen failures can be
# delayed until a feature is used, even when the initial window appears.
./POCOX.AppImage --appimage-extract >/dev/null
export LD_LIBRARY_PATH="$PWD/squashfs-root/usr/bin/lib:$PWD/squashfs-root/usr/lib"
while IFS= read -r -d '' binary; do
  if file "$binary" | grep -q 'ELF.*dynamically linked\|ELF.*shared object'; then
    dependencies=$(ldd "$binary" 2>&1) || { echo "$binary: $dependencies"; exit 1; }
    if grep -q 'not found' <<< "$dependencies"; then
      echo "$binary: $dependencies"
      exit 1
    fi
  fi
done < <(find squashfs-root/usr/bin -type f -print0)
unset LD_LIBRARY_PATH
./POCOX.AppImage --appimage-extract-and-run > app.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; cat app.log' EXIT
for ((i=0; i<30; i++)); do
  kill -0 "$pid"
  if window=$(xdotool search --onlyvisible --name POCOX | head -1); then
    sleep 5
    kill -0 "$pid"
    import -window "$window" /output/window.png
    echo 'POCOX displayed its window and stayed running without network or system WebKit.'
    exit 0
  fi
  sleep 1
done
echo 'POCOX did not display its window.' >&2
exit 1
