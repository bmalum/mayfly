#!/usr/bin/env bash
# Builds the mayfly-shutdown external extension layer for one architecture:
# a tiny static C binary at /opt/extensions/mayfly-shutdown. Attached to a
# function, it makes Lambda send SIGTERM to the runtime before shutdown, which
# Mayfly.Shutdown turns into hooks + Logger.flush.
#
#   layer/build-shutdown-extension.sh --arch arm64|x86_64
#
# Output: layer/dist/mayfly-shutdown-<arch>.zip (+ .sha256). Needs docker or finch;
# the scratch dir lives under layer/dist because container VMs on macOS do not share /tmp.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
arch="arm64"
while [[ $# -gt 0 ]]; do case "$1" in --arch) arch="$2"; shift 2 ;; -h|--help) sed -n '2,9p' "$0"; exit 0 ;; *) echo "unknown option $1" >&2; exit 1 ;; esac; done
case "$arch" in arm64) platform=linux/arm64 ;; x86_64) platform=linux/amd64 ;; *) echo "arch must be arm64 or x86_64" >&2; exit 1 ;; esac
cli="${CONTAINER_CLI:-$(command -v docker || command -v finch)}"
mkdir -p "$here/dist"
work="$here/dist/.shutdown-build-$arch"; rm -rf "$work"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/extensions"
"$cli" run --rm --platform "$platform" -v "$here/shutdown-extension:/src:ro" -v "$work/extensions:/out" amazonlinux:2023 sh -c '
  dnf install -y -q gcc glibc-static >/dev/null &&
  gcc -O2 -static -Wall -Werror -o /out/mayfly-shutdown /src/mayfly-shutdown.c && strip /out/mayfly-shutdown && chmod 755 /out/mayfly-shutdown &&
  file /out/mayfly-shutdown 2>/dev/null || ls -la /out/mayfly-shutdown'
name="mayfly-shutdown-$arch.zip"
rm -f "$here/dist/$name" "$here/dist/$name.sha256"
(cd "$work" && zip -q -X -r "$here/dist/$name" extensions)
(cd "$here/dist" && shasum -a 256 "$name" > "$name.sha256" && cat "$name.sha256")
echo "size: $(du -h "$here/dist/$name" | cut -f1)"
