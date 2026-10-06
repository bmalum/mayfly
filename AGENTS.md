# AGENTS.md – working on Mayfly

Context for coding agents (and humans) contributing to this repository.
Read this before changing anything. The user-facing skill for *building
functions with* Mayfly lives in `skills/mayfly-elixir-lambda/`; the
maintainer skill for *operating* the project is `skills/mayfly-maintainer/`.

## What this is

Mayfly is an AWS Lambda custom runtime for Elixir (`provided.al2023`).
Version `1.0.0-rc.1`. MIT. Author: Karrer (https://karrer.solutions).
Website and docs: https://elixir-aws-lambda.dev (repo `bmalum/mayfly_website`).

## Invariants – do not break these

1. **Nothing starts implicitly.** `mix.exs` has no `mod:`; the runtime runs only
   when `bootstrap` calls `Mayfly.Boot.main/0` or user code calls
   `Mayfly.start_link/1`. Adding Mayfly to a project must not affect `mix test`.
2. **Zero runtime dependencies.** Built-in `JSON` (Elixir ≥ 1.18), HTTP over
   `:gen_tcp` (`Mayfly.HTTP`). `:telemetry` is optional. Do not add `:inets`,
   `:ssl`, Jason, Req, etc. to the runtime path. Mix tasks may use `:inets`
   via `apply/3` after `Code.prepend_path` (see `lambda.doctor`), because Mix
   prunes code paths.
3. **Never report a failure as success.** Every failure mode reaches Lambda as
   `/invocation/<id>/error` or `/init/error` with `errorType`, `errorMessage`,
   `stackTrace` (list). Header `Lambda-Runtime-Function-Error-Type` must be
   `Category.Reason` (`Mayfly.ErrorPayload.header_type/1`).
4. **Release steps are function captures.** `mix.exs` in consumer projects is
   evaluated before deps compile, so never introduce a
   `Mayfly.Release.something()` *call* meant for `mix.exs`.
5. **Layer builds require an exact OTP match.** `bootstrap` verifies the
   layer's `erts-<vsn>` against `releases/start_erl.data` and exits 1 with a
   readable message. Keep that check.
6. **`priv/` ships to consumers.** Only `priv/rel/` belongs there. Never put
   build artefacts (PLTs, dist) under `priv/`.
7. **Public layers are immutable infrastructure.** Never delete a published
   layer version; users' functions reference them. New OTP → new version.

## Layout

```
lib/mayfly.ex              Mayfly.start_link/1, Mayfly.Supervisor (resolve handler once, N pollers)
lib/mayfly/boot.ex         entry point for bootstrap: logger config, start apps, start runtime, exit codes
lib/mayfly/poller.ex       one GenServer per concurrency slot: /next → handler → /response|/error, backoff
lib/mayfly/handler.ex      behaviour (init/1, handle/3), _HANDLER resolution (module or legacy M.f), invoke
lib/mayfly/runtime_api.ex  behaviour + impl of the 4 Runtime API calls, streaming, error headers
lib/mayfly/http.ex         HTTP/1.1 client over :gen_tcp, chunked both ways, trailers, send_timeout
lib/mayfly/response.ex     %Mayfly.Response{} buffered/streaming, Function URL prelude
lib/mayfly/error_payload.ex error documents, header_type/1, X-Ray cause
lib/mayfly/context.ex      per-invocation metadata from headers
lib/mayfly/log_formatter.ex JSON log lines for AWS_LAMBDA_LOG_FORMAT=JSON
lib/mayfly/telemetry.ex    optional :telemetry wrapper
lib/mayfly/release.ex      release steps prepare/1, bootstrap/1, zip/1
lib/mayfly/local_runtime.ex Runtime API emulator (tests, mix lambda.invoke)
lib/mix/tasks/lambda.{build,invoke,doctor}.ex
priv/rel/vm.args.eex       Lambda-tuned vm.args template
layer/                     build.sh, publish.sh, latest-otp.sh, publisher-role.yml, README.md
lambda.Dockerfile          AL2023 image: targets `otp`, `layer`, `build`
skills/                    Agent Skills (user-facing + maintainer)
guides/                    ExDoc extras; published to the website
test/support/              Handlers (every failure mode), FakeRuntime, HttpStub
```

## Commands

```bash
mix deps.get
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors      # must be clean
mix test                                          # 60+ tests, ~1 s
MIX_ENV=test mix dialyzer                          # must be 0 errors (PLTs in _build/plts)
mix docs                                          # must print no warnings
MIX_ENV=test mix release lambda --overwrite       # smoke: builds bootstrap + lambda.zip using test/support handler
mix lambda.invoke Mayfly.Test.Handlers.Echo '{"a":1}'   # (MIX_ENV=test) local run through the real runtime
```

CI (`.github/workflows/ci.yml`) runs all of the above plus an end-to-end run of
the built `bootstrap` against `Mayfly.LocalRuntime`. Keep it green.

## Testing philosophy

- Every module has tests; `test/support/handlers.ex` enumerates every handler
  failure mode (raise, exit, throw, bare value, unencodable, error map, stream
  error). Add a case there when you add a behaviour.
- `Mayfly.LocalRuntime` is the integration seam; prefer it over mocking.
- Before claiming something works on Lambda, deploy it. Playground account
  profile: `elixir-playground` (537124966503, eu-central-1), role
  `mayfly-playground-lambda-role`. Managed Instances need a capacity provider
  (m7g.large works for arm64, MaxVCpuCount ≥ 16, memory ≥ 2048) and are
  billable: delete the provider afterwards.
- Docker is not installed on the maintainer's Mac; `finch` is. `lambda.build`
  and `layer/build.sh` fall back to it automatically (`CONTAINER_CLI=` overrides).

## Releasing the library

1. Update `@version` in `mix.exs` and the CHANGELOG (Keep a Changelog).
2. `git tag v<version> && git push --tags`.
3. `.github/workflows/publish.yml` checks the tag equals `mix.exs`, runs the
   checks, `mix hex.publish --yes` (secret `HEX_API_KEY`, not yet set), and
   creates a GitHub release with the CHANGELOG section (prerelease if the
   version contains `-`).

## Publishing layers (the public Erlang runtime)

Owner account: **mayfly-admin** (651236577491, profile `mayfly-admin`). Never
publish public layers from a sandbox account.

- Workflow `.github/workflows/layers.yml`: weekly (Mon 04:17 UTC) + manual.
  `layer/latest-otp.sh` → newest patch per major in `vars.LAYERS_OTP_MAJORS`
  (`27 28 29`) → native x86_64/arm64 builds → `ssl` smoke test → OIDC role
  `mayfly-layers-publisher` (from `layer/publisher-role.yml`, stack
  `mayfly-layers-publisher`) → `layer/publish.sh --skip-existing --public` to
  `vars.LAYERS_REGIONS` (16 regions) → GitHub release `layers` (ARNS.md,
  arns.json, sha256) → commit `data/layers.json` into `mayfly_website` via
  `secrets.WEBSITE_DEPLOY_KEY` → Cloudflare Pages rebuilds `/layers/`.
- Names: pinned `mayfly-erlang-27-3-4-18-<arch>`, alias `mayfly-erlang-27-<arch>`.
- Add an OTP major: `gh variable set LAYERS_OTP_MAJORS --body "27 28 29"`,
  run the workflow. Add a region: extend `LAYERS_REGIONS`.
- Manual/local: `layer/build.sh --otp X --arch arm64` then
  `AWS_PROFILE=mayfly-admin layer/publish.sh --region R --public`.
- Cost: layer storage is inside Lambda's 75 GB/region free tier; effectively $0.

## Docs and website

- Guides in `guides/` are ExDoc extras; `mix docs -o ../mayfly_website/docs`
  regenerates the site's docs (see the website AGENTS.md). Every ExDoc page
  also exists as `.md`; `docs/llms.txt` is the agent index.
- README, `guides/*.md`, CHANGELOG and the skill must agree. When you change a
  public behaviour, update all four.
- ExDoc head tags (SEO) come from `docs_head/1` in `mix.exs`.

## Style

- `mix format`, no compiler warnings, Dialyzer clean, `@moduledoc` on every
  module, `@impl true` on callbacks.
- Error messages name what was tried (e.g. "neither module X nor module Y
  could be loaded"), never just "not found".
- Inclusive language; no `master`/`slave`/`whitelist`/`blacklist`.

## Known gaps / ideas

- Elixir precompiled layer (separate version axis; deliberately not done).
- `mix lambda.build` still uses `mix release` under the hood only; a
  `--deploy` step is intentionally out of scope (use the AWS CLI / IaC).
- Durable Functions SDK for Elixir would be a separate library on top of
  `Mayfly.Context`.
