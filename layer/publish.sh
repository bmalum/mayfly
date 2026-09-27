#!/usr/bin/env bash
# Publishes layer zips from layer/dist as Lambda layer versions.
#
#   layer/publish.sh                                    # all zips in dist/, eu-central-1 + us-east-1
#   layer/publish.sh --region eu-west-1 --region us-west-2
#   layer/publish.sh --arch arm64 --otp 27.3.4.18       # subset
#   layer/publish.sh --public                           # anyone may use the layer
#   layer/publish.sh --org o-abc123                     # share with an AWS Organization
#   layer/publish.sh --skip-existing                    # idempotent re-runs (CI)
#
# Each zip is published under two layer names:
#   mayfly-erlang-<otp with dashes>-<arch>   e.g. mayfly-erlang-27-3-4-18-arm64  (pinned)
#   mayfly-erlang-<major>-<arch>             e.g. mayfly-erlang-27-arm64          (alias; newest patch)
#
# Writes layer/dist/ARNS.md and layer/dist/arns.json. Needs the aws cli with
# lambda:PublishLayerVersion (+ lambda:AddLayerVersionPermission for sharing).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
regions=() archs=() otps=()
public=false org="" skip_existing=false
name_prefix="${LAYER_NAME_PREFIX:-mayfly-erlang}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) regions+=("$2"); shift 2 ;;
    --arch)   archs+=("$2"); shift 2 ;;
    --otp)    otps+=("$2"); shift 2 ;;
    --public) public=true; shift ;;
    --org)    org="$2"; shift 2 ;;
    --skip-existing) skip_existing=true; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
[[ ${#regions[@]} -gt 0 ]] || regions=(eu-central-1 us-east-1)
command -v aws >/dev/null || { echo "aws cli is required" >&2; exit 1; }

# Discover zips: mayfly-erlang-<otp>-<arch>.zip
zips=()
for f in "$here"/dist/mayfly-erlang-*.zip; do
  [[ -f "$f" ]] || continue
  base="$(basename "$f" .zip)"; rest="${base#mayfly-erlang-}"
  arch="${rest##*-}"; otp="${rest%-*}"
  [[ ${#archs[@]} -eq 0 || " ${archs[*]} " == *" $arch "* ]] || continue
  [[ ${#otps[@]}  -eq 0 || " ${otps[*]} "  == *" $otp "*  ]] || continue
  zips+=("$otp:$arch:$f")
done
[[ ${#zips[@]} -gt 0 ]] || { echo "no matching zips in $here/dist – run layer/build.sh first" >&2; exit 1; }

md="$here/dist/ARNS.md"; json="$here/dist/arns.json"
printf '| Region | OTP | Architecture | Layer ARN (pinned) | Alias ARN |\n|---|---|---|---|---|\n' > "$md"
echo "[" > "$json"; first=true

share() { # region name version
  if $public; then
    aws lambda add-layer-version-permission --region "$1" --layer-name "$2" --version-number "$3" \
      --statement-id public --action lambda:GetLayerVersion --principal '*' >/dev/null
  fi
  if [[ -n "$org" ]]; then
    aws lambda add-layer-version-permission --region "$1" --layer-name "$2" --version-number "$3" \
      --statement-id org --action lambda:GetLayerVersion --principal '*' --organization-id "$org" >/dev/null
  fi
}

existing_arn() { # region name description -> arn of a version with that description, or empty
  aws lambda list-layer-versions --region "$1" --layer-name "$2" \
    --query "LayerVersions[?Description=='$3'].LayerVersionArn | [0]" --output text 2>/dev/null | grep -v '^None$' || true
}

publish() { # region name zip description arch -> arn
  local arn
  if $skip_existing && arn="$(existing_arn "$1" "$2" "$4")" && [[ -n "$arn" ]]; then
    echo "    exists: $arn" >&2; echo "$arn"; return
  fi
  arn=$(aws lambda publish-layer-version --region "$1" --layer-name "$2" \
    --description "$4" --license-info "Apache-2.0" \
    --compatible-runtimes provided.al2023 --compatible-architectures "$5" \
    --zip-file "fileb://$3" --query LayerVersionArn --output text)
  share "$1" "$2" "${arn##*:}"
  echo "    $arn" >&2; echo "$arn"
}

for entry in "${zips[@]}"; do
  IFS=: read -r otp arch zip <<< "$entry"
  sha="$(cut -d' ' -f1 "$zip.sha256" 2>/dev/null || shasum -a 256 "$zip" | cut -d' ' -f1)"
  desc="Erlang/OTP ${otp} for Mayfly (Elixir on Lambda), ${arch}, sha256:${sha:0:16}"
  pinned="${name_prefix}-${otp//./-}-${arch}"
  alias="${name_prefix}-${otp%%.*}-${arch}"

  for region in "${regions[@]}"; do
    echo "==> $otp $arch -> $region"
    arn=$(publish "$region" "$pinned" "$zip" "$desc" "$arch")
    alias_arn=$(publish "$region" "$alias" "$zip" "$desc" "$arch")
    printf '| %s | %s | %s | `%s` | `%s` |\n' "$region" "$otp" "$arch" "$arn" "$alias_arn" >> "$md"
    $first || echo "," >> "$json"; first=false
    printf '  {"region":"%s","otp":"%s","arch":"%s","arn":"%s","alias_arn":"%s","sha256":"%s"}' \
      "$region" "$otp" "$arch" "$arn" "$alias_arn" "$sha" >> "$json"
  done
done
echo "]" >> "$json"

echo; cat "$md"
