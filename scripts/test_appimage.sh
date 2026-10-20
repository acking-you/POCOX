#!/usr/bin/env bash
# Test the actual artifact with no network, FUSE, WebKit or build dependencies.
set -euo pipefail
image=$(realpath "$1")
output=$(realpath -m "${2:-appimage-test-output}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/capture"
chmod 777 "$work/capture"
cat > "$work/Dockerfile" <<'DOCKER'
FROM ubuntu:22.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xvfb xauth xdotool libgtk-3-0 libgl1-mesa-dri libegl1 libasound2 \
    dbus-x11 fonts-dejavu-core ca-certificates file imagemagick && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home tester
USER tester
WORKDIR /tmp
DOCKER
docker build --tag pocox-appimage-test "$work"
docker run --rm --network none --cap-drop ALL \
  --volume "$image:/tmp/POCOX.AppImage:ro" \
  --volume "$work/capture:/output" \
  --volume "$(dirname "$(realpath "$0")"):/checks:ro" \
  pocox-appimage-test dbus-run-session -- xvfb-run -a \
  bash /checks/test_appimage_window.sh
mkdir -p "$output"
cp -a "$work/capture/." "$output/"
