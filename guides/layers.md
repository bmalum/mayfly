# Erlang runtime layers

Mayfly can ship your function without an Erlang runtime (`mayfly: [layer: true]`)
and take ERTS from a Lambda layer instead. The zip then holds only BEAM files
(1–5 MB), builds on any operating system in seconds, and needs no Docker.

## How it works

- The layer unpacks to `/opt/erlang` and contains a full Erlang/OTP compiled
  on Amazon Linux 2023 (`crypto`/`ssl` linked against Lambda's `libcrypto.so.3`).
- The release is assembled with `include_erts: false`; its `bootstrap`
  prepends `/opt/erlang/bin` to `PATH` and, before starting the VM, checks that
  an `erl` exists and that the layer's ERTS version equals the one the release
  was built with (`releases/start_erl.data`). Mismatches fail fast with a clear
  message instead of an obscure boot error.
- Elixir itself (`elixir`, `logger`, `eex`, …) is part of your release, so any
  Elixir version that supports the layer's OTP major works.

**The OTP version must match exactly** (Mix releases without ERTS require the
same ERTS version on the target). Pin your toolchain to the layer's OTP:

```bash
mise use erlang@27.3.4.18 elixir@1.18.4-otp-27     # or asdf / .tool-versions
```

## Naming

| Layer name | Meaning |
|---|---|
| `mayfly-erlang-27-3-4-18-arm64` | pinned OTP 27.3.4.18 build; new versions only for rebuilds of the same OTP |
| `mayfly-erlang-27-arm64` | alias; its newest version is always the latest published 27.x patch |

Layer *versions* are immutable, so pin the full ARN (with version number) in
your infrastructure and bump it deliberately. The layer description contains
the OTP version and the first 16 hex digits of the zip's SHA-256; the full
checksums are attached to the GitHub release `layers`.

## Public layers

Public layers are published by the [Layers workflow](../.github/workflows/layers.yml)
for the latest patch release of each supported OTP major, both architectures,
in these regions:

| OTP major | Elixir | Notes |
|---|---|---|
| 27 | 1.18, 1.19, 1.20 | default in the docs and `lambda.Dockerfile` |
| 28 | 1.19, 1.20 | |
| 29 | 1.20+ | no precompiled Elixir 1.18/1.19 exists for OTP 29 |

Pick the layer that matches the OTP your Elixir was compiled with
(`elixir --version` prints it); `mix lambda.doctor` resolves the ARN.


`eu-central-1 eu-west-1 eu-west-2 eu-west-3 eu-north-1 us-east-1 us-east-2
us-west-1 us-west-2 ca-central-1 sa-east-1 ap-southeast-1 ap-southeast-2
ap-northeast-1 ap-northeast-2 ap-south-1`

Browse them at **[elixir-aws-lambda.dev/layers](https://elixir-aws-lambda.dev/layers/)**
(every OTP version × region × architecture, with copy buttons). The same data
is available as static JSON:

```
GET https://elixir-aws-lambda.dev/layers/27/arm64/eu-central-1.json          # newest 27.x
GET https://elixir-aws-lambda.dev/layers/27.3.4.18/arm64/eu-central-1.json   # pinned
GET https://elixir-aws-lambda.dev/layers/index.json                          # everything
```

`mix lambda.doctor` queries the resolver for your local OTP, `--arch` and
`--region` and prints the matching ARN. Checksums (`.sha256`) and the raw
`ARNS.md`/`arns.json` are attached to the
[layers release](https://github.com/bmalum/mayfly/releases/tag/layers).

Missing a region or OTP version? Open an issue, or run the workflow on your
fork with your own account.

## Publishing to your own account

```bash
layer/build.sh --otp "$(layer/latest-otp.sh 27)" --arch arm64   # docker or finch
layer/publish.sh --region eu-central-1 --region eu-west-1        # prints the ARN table
layer/publish.sh --org o-abc123                                  # share with your AWS Organization
layer/publish.sh --public                                        # share with everyone
```

`layer/publish.sh --skip-existing` is idempotent and safe to re-run. Building
the non-native architecture locally runs under QEMU and is slow; the GitHub
workflow uses native runners for both.

## Automation

`.github/workflows/layers.yml` runs weekly and on demand:

1. `layer/latest-otp.sh` resolves the newest patch of each configured major
   (`vars.LAYERS_OTP_MAJORS`, default `27 28`).
2. A matrix job builds each version natively on `ubuntu-24.04` (x86_64) and
   `ubuntu-24.04-arm` (arm64) and smoke-tests `ssl` on a clean AL2023 image.
3. A publish job assumes an IAM role via GitHub OIDC
   (`secrets.LAYERS_ROLE_ARN`, template in `layer/publisher-role.yml`),
   publishes to all regions (`vars.LAYERS_REGIONS`), grants public access and
   attaches `ARNS.md`, `arns.json` and checksums to the `layers` release.
4. With `secrets.WEBSITE_DEPLOY_KEY` set, it merges `arns.json` into the
   website repository's `data/layers.json`; Cloudflare Pages rebuilds and the
   catalog and resolver at `/layers/` reflect the new versions within minutes.

Set it up once in the publishing account:

```bash
aws cloudformation deploy --stack-name mayfly-layers-publisher \
  --template-file layer/publisher-role.yml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GitHubRepo=<owner>/<repo>
# -> Outputs.RoleArn becomes the GitHub secret LAYERS_ROLE_ARN
```

## Why there is no Elixir layer

Elixir's own applications (`elixir`, `logger`, `iex`) make up about 1.4 MB of
a 1.6 MB layer-mode zip, so a second layer family (`mayfly-elixir-<vsn>-otp-<major>`,
unpacking to `/opt/elixir`) looked attractive. We built it and measured it
rather than argue: a prototype `strip_elixir` release step removed the three
applications from the release, rewrote the boot scripts to load them from a
`$MAYFLY_ELIXIR` boot variable, and `bootstrap` verified the layer's Elixir
version the way it verifies ERTS. The same handler was then deployed three
ways to the playground (arm64, 512 MB, JSON logs, Erlang/OTP 27.3.4.18,
Elixir 1.18.4) and cold-started 21 times each by changing an environment
variable between invocations. `initDurationMs` from `platform.report`:

| Variant | Zip | `update-function-code` | Cold start median | p90 | min–max |
|---|---|---|---|---|---|
| 1. bundled ERTS | 22.4 MB | 10–14 s | 506 ms | 659 ms | 407–673 ms |
| 2. ERTS layer (default) | 1.6 MB | 2.5–4.5 s | 543 ms | 709 ms | 399–728 ms |
| 3. ERTS layer + Elixir layer | 0.16 MB | 1.8–2.5 s | 511 ms | 541 ms | 415–642 ms |

The Elixir layer improves the median cold start by about 30 ms over today's
default, under the 50 ms bar we set for shipping it, and saves roughly one
second per deploy. Against that it adds a second version axis (every Elixir
patch × every OTP major as a layer, matched exactly by `bootstrap`), a second
ARN to attach, and a release step that edits boot scripts. The variance
between runs (p90 differences of 100–170 ms in both directions) is larger
than the effect. The bundled-ERTS variant, for what it is worth, cold-starts
as fast as the layer variants; the layer buys build portability and a small
upload, not speed.

Decision: not shipped. If your fleet deploys dozens of functions per commit
and the upload time matters, open an issue with numbers; the prototype is
small and can be revived.

## Security notes

- A layer is code that runs inside your function. Pin ARNs by version, verify
  the checksum against the release assets if you need to, or publish your own.
- The publishing role can only touch layers named `mayfly-erlang-*` in its
  account and is only assumable from the configured repository and ref.
- Layers should live in a long-lived account you control, not in a personal
  sandbox: functions referencing a deleted layer can no longer be created or
  updated.
