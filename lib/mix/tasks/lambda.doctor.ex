defmodule Mix.Tasks.Lambda.Doctor do
  @shortdoc "Checks the project's Lambda setup (release config, handler, OTP vs layer)"

  @moduledoc """
  Runs a set of checks that catch the common setup mistakes before you deploy:

    * a release with the `Mayfly.Release` steps and a `mayfly: [handler: ...]`
      option exists;
    * the configured handler resolves (module implements `Mayfly.Handler`, or a
      legacy `Module.function` exists) and its `init/1` succeeds;
    * for `layer: true` releases, the local OTP version matches the layer you
      intend to use: `--layer ARN` queries Lambda for that layer's OTP version;
      without it the public layer catalog at elixir-aws-lambda.dev is consulted
      for your OTP, `--arch` (default arm64) and `--region` (default
      `AWS_REGION`/`AWS_DEFAULT_REGION` or eu-central-1) and the matching ARN
      is printed;
    * the Elixir/OTP versions are supported.

      mix lambda.doctor
      mix lambda.doctor --arch x86_64 --region us-east-1
      mix lambda.doctor --release lambda --layer arn:aws:lambda:eu-central-1:123:layer:mayfly-erlang-27-arm64:1

  Exit status is 1 when any check fails.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [release: :string, layer: :string, arch: :string, region: :string]
      )

    Mix.Task.run("app.start")

    results =
      [check_versions(), check_release(opts[:release], opts)]
      |> List.flatten()

    Enum.each(results, &print/1)

    if Enum.any?(results, &match?({:error, _, _}, &1)) do
      Mix.shell().error("\nSome checks failed.")
      exit({:shutdown, 1})
    else
      Mix.shell().info("\nAll checks passed.")
    end
  end

  # -- checks ---------------------------------------------------------------------

  defp check_versions do
    otp = System.otp_release()
    erts = :erlang.system_info(:version) |> List.to_string()

    [
      if(Version.match?(System.version(), "~> 1.18"),
        do: {:ok, "Elixir #{System.version()}", nil},
        else: {:error, "Elixir #{System.version()}", "Mayfly requires Elixir 1.18 or newer"}
      ),
      if(String.to_integer(otp) >= 27,
        do: {:ok, "OTP #{otp} (ERTS #{erts})", nil},
        else: {:error, "OTP #{otp}", "Mayfly requires OTP 27 or newer"}
      )
    ]
  end

  defp check_release(name, opts) do
    releases = Mix.Project.config()[:releases] || []

    case pick_release(releases, name) do
      nil ->
        [
          {:error, "release configuration",
           "no release found#{if name, do: " named #{name}"}. Add to mix.exs:\n" <>
             "      releases: [lambda: [steps: [&Mayfly.Release.prepare/1, :assemble, &Mayfly.Release.bootstrap/1, &Mayfly.Release.zip/1], mayfly: [handler: MyApp.Handler]]]"}
        ]

      {rel_name, config} ->
        mayfly = Keyword.get(config, :mayfly, [])
        steps = Keyword.get(config, :steps, [])

        [
          check_steps(rel_name, steps),
          check_handler(rel_name, mayfly[:handler]),
          check_layer(rel_name, mayfly, opts)
        ]
    end
  end

  defp pick_release(releases, nil), do: List.first(releases)

  defp pick_release(releases, name) do
    Enum.find(releases, fn {n, _} -> Atom.to_string(n) == name end)
  end

  defp check_steps(name, steps) do
    has_bootstrap? = Enum.any?(steps, &step?(&1, :bootstrap))
    has_prepare? = Enum.any?(steps, &step?(&1, :prepare))

    cond do
      not has_bootstrap? ->
        {:error, "release #{name}: steps",
         "steps must include &Mayfly.Release.bootstrap/1 (after :assemble)"}

      not has_prepare? ->
        {:warn, "release #{name}: steps",
         "&Mayfly.Release.prepare/1 is missing; strip_beams/vm.args defaults will not be applied"}

      true ->
        {:ok, "release #{name}: Mayfly.Release steps present", nil}
    end
  end

  defp step?(step, name) when is_function(step, 1) do
    info = Function.info(step)
    info[:module] == Mayfly.Release and info[:name] == name
  end

  defp step?(_, _), do: false

  defp check_handler(name, nil),
    do: {:error, "release #{name}: handler", "mayfly: [handler: ...] is not set"}

  defp check_handler(name, handler) do
    handler_string = if is_atom(handler), do: inspect(handler), else: handler

    case Mayfly.Handler.resolve(handler_string) do
      {:ok, %{module: module}} ->
        kind =
          if function_exported?(module, :handle, 3),
            do: "Mayfly.Handler",
            else: "legacy Module.function"

        {:ok, "release #{name}: handler #{handler_string} (#{kind}), init/1 ok", nil}

      {:error, %{errorType: type, errorMessage: message}} ->
        {:error, "release #{name}: handler #{handler_string}", "#{type}: #{message}"}
    end
  end

  @catalog "https://elixir-aws-lambda.dev/layers"

  defp check_layer(name, mayfly, opts) do
    layer? = Keyword.get(mayfly, :layer, false)
    erts = :erlang.system_info(:version) |> List.to_string()
    otp = otp_version()
    layer_arn = Keyword.get(opts, :layer)

    cond do
      not layer? ->
        {:ok,
         "release #{name}: bundles ERTS #{erts} (build on Amazon Linux 2023 or with --docker)",
         nil}

      is_binary(layer_arn) ->
        compare_with_layer(name, layer_arn, otp, erts)

      true ->
        lookup_public_layer(
          name,
          otp,
          Keyword.get(opts, :arch, "arm64"),
          Keyword.get(opts, :region) || default_region()
        )
    end
  end

  # Resolves the public layer for this exact OTP from the static catalog.
  defp lookup_public_layer(name, otp, arch, region) do
    case fetch_json("#{@catalog}/#{otp}/#{arch}/#{region}.json") do
      {:ok, %{"arn" => arn}} ->
        {:ok, "release #{name}: public layer for OTP #{otp} (#{arch}, #{region}): #{arn}", nil}

      {:error, :not_found} ->
        major = otp |> String.split(".") |> hd()

        hint =
          case fetch_json("#{@catalog}/#{major}/#{arch}/#{region}.json") do
            {:ok, %{"otp" => avail}} ->
              "no public layer for OTP #{otp}; the newest published #{major}.x is #{avail}. " <>
                "Build with `mise use erlang@#{avail}`, or publish your own (layer/build.sh)"

            _ ->
              "no public layer for OTP #{major}.x in #{region}/#{arch}. " <>
                "Publish your own with layer/build.sh + layer/publish.sh"
          end

        {:warn, "release #{name}: layer build, local OTP #{otp}", hint}

      {:error, reason} ->
        {:warn, "release #{name}: layer build, local OTP #{otp}",
         "could not reach the layer catalog (#{inspect(reason)}); " <>
           "attach a layer built from OTP #{otp} exactly, or pass --layer ARN"}
    end
  end

  defp fetch_json(url), do: Mix.Tasks.Lambda.Catalog.fetch_json(url)

  defp default_region, do: Mix.Tasks.Lambda.Catalog.default_region()

  defp compare_with_layer(name, arn, otp, erts) do
    case System.cmd(
           "aws",
           [
             "lambda",
             "get-layer-version-by-arn",
             "--arn",
             arn,
             "--query",
             "Description",
             "--output",
             "text"
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Regex.run(~r/Erlang\/OTP (\d+(?:\.\d+)+)/, out) do
          [_, ^otp] ->
            {:ok, "release #{name}: layer provides OTP #{otp}, matches local ERTS #{erts}", nil}

          [_, layer_otp] ->
            {:error,
             "release #{name}: layer provides OTP #{layer_otp} but local toolchain is OTP #{otp}",
             "build with OTP #{layer_otp} (mise use erlang@#{layer_otp}) or attach a layer for OTP #{otp}"}

          nil ->
            {:warn, "release #{name}: layer #{arn}",
             "description does not state an OTP version: #{String.trim(out)}"}
        end

      {out, _} ->
        {:warn, "release #{name}: could not query layer #{arn}", String.trim(out)}
    end
  end

  # Full OTP version (e.g. 27.3.4.18) from the OTP_VERSION file, falling back to the major.
  defp otp_version do
    path = Path.join([:code.root_dir(), "releases", System.otp_release(), "OTP_VERSION"])

    case File.read(path) do
      {:ok, v} -> String.trim(v)
      _ -> System.otp_release()
    end
  end

  # -- output -----------------------------------------------------------------------

  defp print({:ok, label, _}), do: Mix.shell().info([:green, "✓ ", :reset, label])

  defp print({:warn, label, hint}),
    do: Mix.shell().info([:yellow, "! ", :reset, label, "\n    ", hint])

  defp print({:error, label, hint}), do: Mix.shell().error("✗ #{label}\n    #{hint}")
end
