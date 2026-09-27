# Mayfly ERTS layer tooling

Scripts that build, publish and share the Erlang runtime layers used by
`mayfly: [layer: true]` releases. User documentation (contract, public ARNs,
naming) is in [`guides/layers.md`](../guides/layers.md).

| File | Purpose |
|---|---|
| `latest-otp.sh [MAJOR...]` | prints the newest OTP patch release per major (GitHub releases API) |
| `build.sh [--otp V]... [--arch A]` | builds `dist/mayfly-erlang-<otp>-<arch>.zip` (+ `.sha256`) from the `layer` target of `../lambda.Dockerfile`, using docker or finch |
| `publish.sh [--region R]... [--public] [--org ID] [--skip-existing]` | publishes every zip in `dist/` as `mayfly-erlang-<otp>-<arch>` (pinned) and `mayfly-erlang-<major>-<arch>` (alias); writes `dist/ARNS.md` and `dist/arns.json` |
| `publisher-role.yml` | CloudFormation: IAM role for the GitHub Actions workflow (OIDC) |

`../.github/workflows/layers.yml` runs these weekly for the latest patch of
each configured OTP major on native x86_64/arm64 runners and attaches the
results to the GitHub release `layers`.

## Layout of a layer zip

```
erlang/
  bin/erl            → symlinks into lib/erlang/bin
  lib/erlang/
    erts-<vsn>/      the VM (JIT enabled)
    lib/<app>-<vsn>/ OTP applications without src/doc/examples
```

OpenSSL is linked dynamically against Amazon Linux 2023's `libcrypto.so.3`,
which the `provided.al2023` runtime provides; the build fails if `crypto` is
missing. Excluded applications: `wx`, `debugger`, `observer`, `et`, `megaco`,
`odbc`, `jinterface`, `diameter`, `eldap`, `ftp`, `tftp`, `snmp`.

`dist/` is git-ignored.
