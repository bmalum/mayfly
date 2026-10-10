#!/usr/bin/env bash
# Rewrites the Mayfly layer ARN maps inside templates/{sam,terraform,cdk} from
# the public catalog (https://elixir-aws-lambda.dev/layers/index.json) or a
# local data file. Only the blocks between "mayfly-layers:begin/end" markers
# are touched; everything else in the templates is hand-maintained.
#
#   layer/render-templates.sh                 # fetch the catalog
#   layer/render-templates.sh path/to/layers.json
#
# Exit code 0 always; prints "changed" or "unchanged" so CI can decide whether
# to commit.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-https://elixir-aws-lambda.dev/layers/index.json}"
if [[ "$src" == http* ]]; then
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  curl -fsSL -A "mayfly-render-templates" -o "$tmp" "$src"
  src="$tmp"
fi
python3 - "$root" "$src" <<'PY'
import json, re, sys, datetime
root, src = sys.argv[1], sys.argv[2]
data = json.load(open(src))
layers = data["layers"] if isinstance(data, dict) else data
# These ARNs end up committed into IaC templates: refuse anything that is not a layer ARN.
arn_re = re.compile(r"^arn:aws:lambda:[a-z0-9-]+:\d{12}:layer:mayfly-erlang-[0-9-]+-(arm64|x86_64):\d+$")
bad = [l for l in layers if not arn_re.match(l.get("arn", ""))]
if bad:
    sys.exit(f"refusing to render: {len(bad)} catalog entries have unexpected ARNs, e.g. {bad[0]}")
generated = data.get("generated", datetime.date.today().isoformat()) if isinstance(data, dict) else datetime.date.today().isoformat()

# Newest patch per (region, otp major, arch); use the pinned ARN so deployments are reproducible.
def vkey(v): return tuple(int(x) for x in v.split("."))
best = {}
for l in layers:
    k = (l["region"], l["otp"].split(".")[0], l["arch"])
    if k not in best or vkey(l["otp"]) > vkey(best[k]["otp"]):
        best[k] = l
regions = sorted({k[0] for k in best})
def entries(region):
    # CloudFormation mapping keys must be alphanumeric: x86_64 -> x8664.
    return sorted((f"otp{k[1]}{k[2].replace('_', '')}", v["arn"]) for k, v in best.items() if k[0] == region)

def sam():
    out = ["  MayflyLayers:"]
    for r in regions:
        out.append(f"    {r}:")
        for key, arn in entries(r): out.append(f"      {key}: {arn}")
    return "\n".join(out)
def tf():
    out = ["  mayfly_layers = {"]
    for r in regions:
        out.append(f'    "{r}" = {{')
        for key, arn in entries(r): out.append(f'      {key} = "{arn}"')
        out.append("    }")
    out.append("  }")
    return "\n".join(out)
def cdk():
    out = ["export const MAYFLY_LAYERS: Record<string, Record<string, string>> = {"]
    for r in regions:
        out.append(f'  "{r}": {{')
        for key, arn in entries(r): out.append(f'    {key}: "{arn}",')
        out.append("  },")
    out.append("};")
    return "\n".join(out)

targets = {
    "templates/sam/template.yaml": ("  # mayfly-layers:begin", "  # mayfly-layers:end", sam),
    "templates/terraform/locals.tf": ("  # mayfly-layers:begin", "  # mayfly-layers:end", tf),
    "templates/cdk/lib/mayfly-function.ts": ("// mayfly-layers:begin", "// mayfly-layers:end", cdk),
}
changed = False
for rel, (begin, end, render) in targets.items():
    path = f"{root}/{rel}"
    text = open(path).read()
    pattern = re.compile(re.escape(begin) + r"[^\n]*\n.*?" + re.escape(end), re.S)
    assert pattern.search(text), f"markers missing in {rel}"
    block = f"{begin} (generated {generated} from the Mayfly catalog)\n{render()}\n{end}"
    new = pattern.sub(lambda _: block, text)
    if new != text:
        open(path, "w").write(new); changed = True
        print(f"  rendered {rel}")
print(f"{len(regions)} regions, {len(best)} layer entries")
print("changed" if changed else "unchanged")
PY
