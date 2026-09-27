#!/usr/bin/env bash
# Prints the latest OTP patch release for each given major, one per line.
#
#   layer/latest-otp.sh            # -> 27.3.4.18  28.5.0.7   (defaults)
#   layer/latest-otp.sh 27 28 29
#
# Used by the layers workflow to build layers for current patch releases
# automatically. Needs curl and python3.
set -euo pipefail
majors=("$@"); [[ ${#majors[@]} -gt 0 ]] || majors=(27 28)

curl -fsSL -H "Accept: application/vnd.github+json" ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
  "https://api.github.com/repos/erlang/otp/releases?per_page=100" |
python3 -c '
import sys, json, re
wanted = [int(m) for m in sys.argv[1:]]
best = {}
for r in json.load(sys.stdin):
    if r.get("prerelease") or r.get("draft"):
        continue
    m = re.fullmatch(r"OTP-(\d+(?:\.\d+)+)", r["tag_name"])
    if not m:
        continue
    parts = tuple(int(x) for x in m.group(1).split("."))
    if parts[0] in wanted and (parts[0] not in best or parts > best[parts[0]]):
        best[parts[0]] = parts
missing = [m for m in wanted if m not in best]
if missing:
    sys.exit(f"no release found for OTP major(s): {missing}")
for major in wanted:
    print(".".join(map(str, best[major])))
' "${majors[@]}"
