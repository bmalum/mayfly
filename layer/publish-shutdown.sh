#!/usr/bin/env bash
# Publishes the mayfly-shutdown extension layers (layer/dist/mayfly-shutdown-<arch>.zip)
# to one or more regions as `mayfly-shutdown-<arch>`. Idempotent on the zip's
# sha256 (kept in the version description). Writes layer/dist/shutdown-arns.json.
#
#   layer/publish-shutdown.sh --region eu-central-1 [--region ...] [--public] [--skip-existing]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
regions=(); public=false; skip_existing=false
while [[ $# -gt 0 ]]; do case "$1" in
  --region) regions+=("$2"); shift 2 ;; --public) public=true; shift ;; --skip-existing) skip_existing=true; shift ;;
  -h|--help) sed -n '2,6p' "$0"; exit 0 ;; *) echo "unknown option $1" >&2; exit 1 ;; esac; done
[[ ${#regions[@]} -gt 0 ]] || regions=(eu-central-1 us-east-1)
json="$here/dist/shutdown-arns.json"; echo "[" > "$json"; first=true
for arch in arm64 x86_64; do
  zip="$here/dist/mayfly-shutdown-$arch.zip"; [[ -f "$zip" ]] || { echo "missing $zip – run layer/build-shutdown-extension.sh --arch $arch" >&2; exit 1; }
  sha="$(cut -d' ' -f1 "$zip.sha256" 2>/dev/null || shasum -a 256 "$zip" | cut -d' ' -f1)"
  desc="mayfly-shutdown extension for Mayfly (SIGTERM on environment shutdown), ${arch}, sha256:${sha:0:16}"
  name="mayfly-shutdown-$arch"
  for region in "${regions[@]}"; do
    echo "==> $name -> $region"
    arn=""
    if $skip_existing; then
      arn="$(aws lambda list-layer-versions --region "$region" --layer-name "$name" --query "LayerVersions[?Description=='$desc'].LayerVersionArn | [0]" --output text 2>/dev/null | grep -v '^None$' || true)"
      [[ -n "$arn" ]] && echo "    exists: $arn"
    fi
    if [[ -z "$arn" ]]; then
      arn=$(aws lambda publish-layer-version --region "$region" --layer-name "$name" --description "$desc" --license-info MIT \
        --compatible-runtimes provided.al2023 --compatible-architectures "$arch" --zip-file "fileb://$zip" --query LayerVersionArn --output text)
      $public && aws lambda add-layer-version-permission --region "$region" --layer-name "$name" --version-number "${arn##*:}" \
        --statement-id public --action lambda:GetLayerVersion --principal '*' >/dev/null
      echo "    $arn"
    fi
    $first || echo "," >> "$json"; first=false
    printf '  {"region":"%s","arch":"%s","arn":"%s","sha256":"%s"}' "$region" "$arch" "$arn" "$sha" >> "$json"
  done
done
echo "]" >> "$json"; echo; cat "$json"
