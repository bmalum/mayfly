defmodule Mayfly.Release do
  @moduledoc """
  Turns `mix release` into a Lambda package builder.

      # mix.exs
      def project do
        [
          releases: [
            lambda: [
              steps: [&Mayfly.Release.prepare/1, :assemble, &Mayfly.Release.bootstrap/1, &Mayfly.Release.zip/1],
              mayfly: [handler: MyApp.Handler]
            ]
          ]
        ]
      end

      MIX_ENV=prod mix release lambda      # -> _build/prod/rel/lambda/lambda.zip

  Use function captures, not a call such as `Mayfly.Release.steps()`: `mix.exs`
  is evaluated before dependencies are compiled, and a capture of a remote
  function does not require the module to be loaded, so `mix deps.get` on a
  fresh clone works. Drop `&Mayfly.Release.zip/1` if you only want the
  directory.

  ## `:mayfly` options

    * `:handler` (required) – module implementing `Mayfly.Handler` or a
      `"Module.function"` string. Written into `bootstrap` as the default
      `_HANDLER`; the Lambda **Handler** setting overrides it.
    * `:layer` – build for the Mayfly ERTS layer: sets `include_erts: false`
      and makes `bootstrap` use `/opt/erlang/bin/erl` (default `false`).
      The zip then contains only BEAM files and can be built on any OS.

  `prepare/1` applies these defaults unless you set them yourself:
  `include_executables_for: [:unix]`, `strip_beams: true`,
  `rel_templates_path` pointing at Mayfly's `vm.args`/`env.sh` (no
  distribution, `+sbwt none`, `RELEASE_TMP=/tmp`).

  Everything else is a normal release: umbrellas, several releases,
  `config/runtime.exs`, `--overwrite`, `MIX_ENV=prod`.
  """

  @doc "Release step (before `:assemble`): applies Lambda-friendly defaults."
  @spec prepare(Mix.Release.t()) :: Mix.Release.t()
  def prepare(%Mix.Release{options: options} = release) do
    mayfly = Keyword.get(options, :mayfly, [])
    Keyword.fetch!(mayfly, :handler)
    layer? = Keyword.get(mayfly, :layer, false)

    options =
      options
      |> Keyword.put_new(:include_executables_for, [:unix])
      |> Keyword.put_new(:strip_beams, true)
      |> Keyword.put_new(:rel_templates_path, Path.join(:code.priv_dir(:mayfly), "rel"))

    release = %{release | options: options}

    if layer? or Keyword.get(options, :include_erts) == false,
      do: %{release | erts_source: nil},
      else: release
  end

  @doc """
  Release step: writes an executable `bootstrap` into the release root.

  Lambda runs `bootstrap` from `/var/task`. The script sets `RELEASE_TMP=/tmp`
  (`/var/task` is read-only), disables distribution and runs
  `bin/<release> eval "Mayfly.Boot.main()"`. When ERTS is not bundled it
  prepends the layer's `/opt/erlang/bin` (or `$MAYFLY_ERTS/bin`) to `PATH`.
  """
  @spec bootstrap(Mix.Release.t()) :: Mix.Release.t()
  def bootstrap(%Mix.Release{} = release) do
    handler =
      release.options |> Keyword.get(:mayfly, []) |> Keyword.get(:handler) ||
        Mix.raise("releases: #{release.name}: missing mayfly: [handler: ...]")

    path = Path.join(release.path, "bootstrap")
    File.write!(path, bootstrap_content(release.name, handler, release.erts_source == nil))
    File.chmod!(path, 0o755)
    Mix.shell().info([:green, "* creating ", :reset, Path.relative_to_cwd(path)])
    release
  end

  @doc "Release step: zips the release directory into `<release path>/lambda.zip`."
  @spec zip(Mix.Release.t()) :: Mix.Release.t()
  def zip(%Mix.Release{} = release) do
    zip_path = Path.join(release.path, "lambda.zip")
    File.rm(zip_path)

    files =
      release.path
      |> File.ls!()
      |> Enum.reject(&(&1 == "lambda.zip"))
      |> Enum.map(&String.to_charlist/1)

    case :zip.create(String.to_charlist(zip_path), files, cwd: String.to_charlist(release.path)) do
      {:ok, _} ->
        size = File.stat!(zip_path).size |> div(1024)

        Mix.shell().info([
          :green,
          "* creating ",
          :reset,
          "#{Path.relative_to_cwd(zip_path)} (#{size} KiB)"
        ])

        release

      {:error, reason} ->
        Mix.raise("Failed to create #{zip_path}: #{inspect(reason)}")
    end
  end

  @doc false
  def bootstrap_content(release_name, handler, layer?) do
    erts_lines =
      if layer? do
        """
        # ERTS is not bundled: use the Mayfly layer (/opt/erlang) or MAYFLY_ERTS.
        MAYFLY_ERTS="${MAYFLY_ERTS:-/opt/erlang}"
        export PATH="$MAYFLY_ERTS/bin:$PATH"
        ERTS_VSN="$(cut -d' ' -f1 "$LAMBDA_TASK_ROOT/releases/start_erl.data")"
        if [ ! -x "$MAYFLY_ERTS/bin/erl" ]; then
          echo "Mayfly: no Erlang runtime at $MAYFLY_ERTS – attach the mayfly-erlang layer for this architecture (or set MAYFLY_ERTS)" >&2
          exit 1
        fi
        if [ ! -d "$MAYFLY_ERTS/lib/erlang/erts-$ERTS_VSN" ] && [ ! -d "$MAYFLY_ERTS/erts-$ERTS_VSN" ]; then
          found="$(ls -d "$MAYFLY_ERTS"/lib/erlang/erts-* "$MAYFLY_ERTS"/erts-* 2>/dev/null | sed 's/.*erts-//' | tr '\\n' ' ')"
          echo "Mayfly: release was built for ERTS $ERTS_VSN but the layer at $MAYFLY_ERTS provides ${found:-nothing} – build with the layer's OTP version or attach the matching layer" >&2
          exit 1
        fi
        """
      else
        ""
      end

    """
    #!/bin/bash
    set -eu

    export LAMBDA_TASK_ROOT="${LAMBDA_TASK_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
    cd "$LAMBDA_TASK_ROOT"

    # /var/task is read-only; releases write sys.config/vm.args to RELEASE_TMP.
    export RELEASE_TMP="${RELEASE_TMP:-/tmp}"
    export RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-none}"
    # One scheduler on standard Lambda (single vCPU, one invocation at a time);
    # Managed Instances run several invocations on several vCPUs, keep the default.
    if [ "${AWS_LAMBDA_MAX_CONCURRENCY:-1}" = "1" ]; then
      export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu +S 1:1}"
    else
      export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}"
    fi
    export _HANDLER="${_HANDLER:-#{handler_string(handler)}}"
    #{erts_lines}
    exec "$LAMBDA_TASK_ROOT/bin/#{release_name}" eval "Mayfly.Boot.main()"
    """
  end

  defp handler_string(module) when is_atom(module), do: inspect(module)
  defp handler_string(string) when is_binary(string), do: string
end
