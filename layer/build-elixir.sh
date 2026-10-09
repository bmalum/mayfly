#!/usr/bin/env bash
# Builds a Mayfly Elixir layer zip from the official precompiled Elixir build.
#
#   layer/build-elixir.sh --elixir 1.18.4 --otp 27
#
# The layer unpacks to /opt/elixir/lib/<app>-<vsn>/ebin and contains only the
# applications a release needs at run time: elixir, logger, eex. mix, iex and
# ex_unit are dropped. BEAM files are architecture independent, so one zip
# serves both x86_64 and arm64.
#
# Output: layer/dist/mayfly-elixir-<elixir>-otp-<major>.zip (+ .sha256)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
elixir="" otp=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --elixir) elixir="$2"; shift 2 ;;
    --otp)    otp="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
[[ -n "$elixir" && -n "$otp" ]] || { echo "usage: $0 --elixir X.Y.Z --otp MAJOR" >&2; exit 1; }

url="https://builds.hex.pm/builds/elixir/v${elixir}-otp-${otp}.zip"
name="mayfly-elixir-${elixir}-otp-${otp}.zip"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$here/dist"

echo "==> downloading $url"
curl -fsSL -o "$work/elixir.zip" "$url"
mkdir -p "$work/src" && unzip -q "$work/elixir.zip" -d "$work/src"

mkdir -p "$work/layer/elixir/lib"
for app in elixir logger eex; do
  src="$work/src/lib/$app"
  [[ -d "$src/ebin" ]] || { echo "missing $app in the Elixir build" >&2; exit 1; }
  # Only ebin is needed at run time; the .app file carries the version.
  vsn="$(sed -n 's/.*{vsn,"\([^"]*\)"}.*/\1/p' "$src/ebin/$app.app" | head -1)"
  [[ -n "$vsn" ]] || { echo "could not read vsn of $app" >&2; exit 1; }
  mkdir -p "$work/layer/elixir/lib/$app-$vsn"
  cp -R "$src/ebin" "$work/layer/elixir/lib/$app-$vsn/ebin"
done
# Strip debug info and docs chunks exactly like `mix release` (strip_beams: true)
# so the layer is byte-for-byte what a release would have shipped.
echo "==> stripping beams"
erl -noshell -eval "
  Files = filelib:wildcard(\"$work/layer/elixir/lib/*/ebin/*.beam\"),
  {ok, _} = beam_lib:strip_files(Files),
  io:format(\"    stripped ~p modules~n\", [length(Files)]), halt()."

printf '%s\n' "$elixir" > "$work/layer/elixir/VERSION"
printf 'otp-%s\n' "$otp" > "$work/layer/elixir/OTP"

echo "==> packaging $here/dist/$name"
rm -f "$here/dist/$name" "$here/dist/$name.sha256"
(cd "$work/layer" && zip -q -r -9 "$here/dist/$name" elixir)
(cd "$here/dist" && shasum -a 256 "$name" > "$name.sha256" && cat "$name.sha256")
du -h "$here/dist/$name" | cut -f1 | xargs echo "    size:"
echo "    contents:"; unzip -l "$here/dist/$name" | awk '/\/$/ && NF==4 {print "      " $4}' | grep -E "^      elixir/lib/[^/]+/$"
