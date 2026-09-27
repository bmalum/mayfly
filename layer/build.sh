#!/usr/bin/env bash
# Builds Mayfly ERTS layer zips: Erlang/OTP compiled on Amazon Linux 2023,
# packaged so Lambda unpacks it to /opt/erlang.
#
#   layer/build.sh                                   # OTP 27.3.4, both architectures
#   layer/build.sh --arch arm64                      # one architecture
#   layer/build.sh --otp 27.3.4.18 --otp 28.5.0.7    # several OTP versions
#   layer/build.sh --otp "$(layer/latest-otp.sh 27)" # latest patch of a major
#
# Uses docker, or finch when docker is not installed (CONTAINER_CLI overrides).
# Output: layer/dist/mayfly-erlang-<otp>-<arch>.zip plus .sha256
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
otps=()
archs=(x86_64 arm64)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) archs=("$2"); shift 2 ;;
    --otp)  otps+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
[[ ${#otps[@]} -gt 0 ]] || otps=("${OTP_VERSION:-27.3.4}")

CLI="${CONTAINER_CLI:-$(command -v docker || command -v finch || true)}"
[[ -n "$CLI" ]] || { echo "docker or finch is required" >&2; exit 1; }
mkdir -p "$here/dist"

for otp in "${otps[@]}"; do
  for arch in "${archs[@]}"; do
    case "$arch" in
      x86_64) platform=linux/amd64 ;;
      arm64)  platform=linux/arm64 ;;
      *) echo "unsupported arch $arch" >&2; exit 1 ;;
    esac

    image="mayfly-layer:${otp}-${arch}"
    name="mayfly-erlang-${otp}-${arch}.zip"
    out="$here/dist/$name"

    echo "==> building $image ($platform)"
    "$CLI" build --progress=plain --platform "$platform" --target layer \
      --build-arg "OTP_VERSION=${otp}" \
      -t "$image" -f "$root/lambda.Dockerfile" "$root"

    echo "==> packaging $out"
    rm -f "$out" "$out.sha256"
    # zip inside the container so symlinks/permissions are preserved verbatim.
    "$CLI" run --rm --platform "$platform" -v "$here/dist:/dist" "$image" \
      sh -c "dnf install -y -q zip >/dev/null && cd /opt && zip -q -r -y -9 /dist/$name erlang"
    (cd "$here/dist" && shasum -a 256 "$name" > "$name.sha256" && cat "$name.sha256")
  done
done

echo
echo "Done. Publish with: layer/publish.sh --region eu-central-1"
