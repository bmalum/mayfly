defmodule Mix.Tasks.Lambda.New do
  @shortdoc "Generates a ready-to-deploy Mayfly Lambda project (optionally with SAM, Terraform or CDK)"

  @moduledoc """
  Generates a new Elixir project that builds and deploys as an AWS Lambda
  function with Mayfly.

      mix lambda.new hello
      mix lambda.new hello --iac sam --arch arm64 --otp 27
      mix lambda.new hello --iac terraform --region eu-west-1
      mix lambda.new hello --iac cdk

  The project contains a `Mayfly.Handler` with an HTTP branch
  (`Mayfly.Events.decode/1`), the release configuration for the Mayfly ERTS
  layer, a `.tool-versions` pinning Erlang to the newest OTP patch the public
  layer provides for `--otp` (looked up in the layer catalog; a built-in
  table is used when offline) and a matching Elixir, an ExUnit test running
  the handler through `Mayfly.LocalRuntime`, a README with the three commands
  that matter, and – with `--iac` – an `infra/` folder holding a working SAM,
  Terraform or CDK definition whose layer ARN map covers all public regions.

  The task ships with the `mayfly` package, so it is available in any project
  that depends on it. For a green-field project without a mix.exs yet:

      mix new tmp && cd tmp && mix deps.get   # with {:mayfly, "~> 1.0.0-rc"} in deps
      mix lambda.new ../hello --iac sam

  or run it from a checkout of Mayfly.

  ## Options

      --iac       sam | terraform | cdk | none (default none)
      --arch      arm64 (default) | x86_64
      --otp       27 (default) | 28 | 29 – OTP major of the layer and the toolchain
      --region    AWS region for the IaC defaults (default $AWS_REGION or eu-central-1)
      --module    Root module name (default derived from the project name)
      --mayfly    Dependency spec for mayfly; default `"~> 1.0.0-rc"`, or
                  `path:/abs/path` to use a local checkout
  """

  use Mix.Task

  alias Mix.Tasks.Lambda.Catalog

  @switches [
    iac: :string,
    arch: :string,
    otp: :string,
    region: :string,
    module: :string,
    mayfly: :string,
    help: :boolean
  ]
  @iacs ~w(sam terraform cdk none)
  @archs ~w(arm64 x86_64)
  @otps ~w(27 28 29)

  @impl true
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid options: #{inspect(invalid)}. See `mix help lambda.new`.")

      argv == [] ->
        Mix.raise(
          "Usage: mix lambda.new PATH [--iac sam|terraform|cdk] [--arch arm64|x86_64] [--otp 27|28|29]"
        )

      true ->
        generate(hd(argv), opts)
    end
  end

  @doc false
  def generate(path, opts) do
    iac = Keyword.get(opts, :iac, "none")
    arch = Keyword.get(opts, :arch, "arm64")
    otp = Keyword.get(opts, :otp, "27")
    iac in @iacs || Mix.raise("--iac must be one of #{Enum.join(@iacs, ", ")}")
    arch in @archs || Mix.raise("--arch must be arm64 or x86_64")
    otp in @otps || Mix.raise("--otp must be one of #{Enum.join(@otps, ", ")}")

    app = path |> Path.basename() |> String.replace("-", "_")
    check_app_name!(app)
    module = Keyword.get(opts, :module, Macro.camelize(app))
    region = Keyword.get(opts, :region, Catalog.default_region())

    File.exists?(path) && File.ls!(path) != [] &&
      Mix.raise("#{path} already exists and is not empty")

    {otp_full, layer_arn, source} = resolve_otp(otp, arch, region)
    elixir = Catalog.elixir_for(otp)

    assigns = %{
      app: app,
      module: module,
      function_name: String.replace(app, "_", "-"),
      arch: arch,
      otp: otp,
      otp_full: otp_full,
      elixir: elixir,
      region: region,
      layer_arn: layer_arn,
      iac: iac,
      mayfly_dep: mayfly_dep(Keyword.get(opts, :mayfly))
    }

    files = project_files(assigns) ++ iac_files(assigns)

    for {rel, content} <- files do
      target = Path.join(path, rel)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content)
      Mix.shell().info([:green, "* creating ", :reset, target])
    end

    Mix.shell().info("""

    Toolchain: Erlang #{otp_full} / Elixir #{elixir} (#{source}); run `mise install` (or asdf) in #{path}.

    Next:
        cd #{path}
        mix deps.get
        mix test
        mix lambda.invoke #{module}.Handler '{"name":"world"}'
        MIX_ENV=prod mix release lambda       # -> _build/prod/rel/lambda/lambda.zip
    #{deploy_hint(assigns)}
    """)
  end

  # -- resolution ----------------------------------------------------------------------

  defp resolve_otp(otp, arch, region) do
    case Catalog.layer(otp, arch, region) do
      {:ok, %{"otp" => full, "arn" => arn}} ->
        {full, arn, "from the layer catalog"}

      {:error, reason} ->
        full = Catalog.offline_otp(otp)

        Mix.shell().info([
          :yellow,
          "* catalog unavailable (#{inspect(reason)}); using built-in OTP #{full}. Check https://elixir-aws-lambda.dev/layers/ before deploying."
        ])

        {full, nil, "built-in table, catalog unreachable"}
    end
  end

  defp mayfly_dep(nil), do: ~s({:mayfly, "~> 1.0.0-rc"})
  defp mayfly_dep("path:" <> path), do: ~s({:mayfly, path: "#{path}"})
  defp mayfly_dep(spec), do: ~s({:mayfly, "#{spec}"})

  defp check_app_name!(app) do
    Regex.match?(~r/^[a-z][a-z0-9_]*$/, app) ||
      Mix.raise(
        "Project name must start with a letter and contain only lowercase letters, numbers and underscores, got: #{app}"
      )
  end

  # -- project files -------------------------------------------------------------------

  defp project_files(a) do
    [
      {"mix.exs", mix_exs(a)},
      {".tool-versions", "erlang #{a.otp_full}\nelixir #{a.elixir}-otp-#{a.otp}\n"},
      {".gitignore",
       "/_build/\n/deps/\n/cover/\n/doc/\nerl_crash.dump\n*.ez\nlambda.zip\n.sam/\n.aws-sam/\ninfra/node_modules/\ninfra/cdk.out/\ninfra/.terraform/\ninfra/*.tfstate*\n"},
      {".formatter.exs",
       "[\n  inputs: [\"{mix,.formatter}.exs\", \"{config,lib,test}/**/*.{ex,exs}\"]\n]\n"},
      {"lib/#{a.app}/handler.ex", handler(a)},
      {"test/test_helper.exs", "ExUnit.start()\n"},
      {"test/#{a.app}/handler_test.exs", handler_test(a)},
      {"README.md", readme(a)}
    ]
  end

  defp mix_exs(a) do
    """
    defmodule #{a.module}.MixProject do
      use Mix.Project

      def project do
        [
          app: #{inspect(String.to_atom(a.app))},
          version: "0.1.0",
          elixir: "~> 1.18",
          start_permanent: Mix.env() == :prod,
          deps: deps(),
          releases: [
            lambda: [
              steps: [
                &Mayfly.Release.prepare/1,
                :assemble,
                &Mayfly.Release.bootstrap/1,
                &Mayfly.Release.zip/1
              ],
              # layer: true -> the zip holds only BEAM files; attach the mayfly-erlang-#{a.otp}-#{a.arch} layer.
              mayfly: [handler: #{a.module}.Handler, layer: true]
            ]
          ]
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end

      defp deps do
        [
          #{a.mayfly_dep}
        ]
      end
    end
    """
  end

  defp handler(a) do
    """
    defmodule #{a.module}.Handler do
      @moduledoc "Lambda entry point. Set the function handler to `#{a.module}.Handler`."
      use Mayfly.Handler

      require Logger

      # Runs once per execution environment, before the first event.
      @impl true
      def init(_opts) do
        {:ok, %{started_at: DateTime.utc_now()}}
      end

      @impl true
      def handle(event, %Mayfly.Context{} = ctx, state) do
        case Mayfly.Events.decode(event) do
          # Function URL / API Gateway request: answer with an HTTP response.
          {:ok, %Mayfly.Events.HTTP.Request{} = req} ->
            name = req.query["name"] || get_in(req.body, ["name"]) || "world"
            Mayfly.Events.HTTP.json(200, greeting(name, ctx, state), req)

          # Direct invoke, EventBridge, SQS, ...: return a JSON-encodable term.
          _ ->
            {:ok, greeting(event["name"] || "world", ctx, state)}
        end
      end

      defp greeting(name, ctx, state) do
        Logger.info("greeting", name: name)

        %{
          message: "Hello, \#{name}!",
          request_id: ctx.request_id,
          remaining_ms: Mayfly.Context.remaining_time_ms(ctx),
          cold_started_at: state.started_at
        }
      end
    end
    """
  end

  defp handler_test(a) do
    """
    defmodule #{a.module}.HandlerTest do
      use ExUnit.Case, async: true

      alias Mayfly.LocalRuntime

      setup do
        rt = start_supervised!({LocalRuntime, []})

        {:ok, _} =
          Mayfly.start_link(
            handler: "#{a.module}.Handler",
            runtime_api: LocalRuntime.address(rt),
            name: nil
          )

        %{rt: rt}
      end

      test "direct invoke", %{rt: rt} do
        assert {:ok, %{body: body}} = LocalRuntime.invoke(rt, %{"name" => "Ada"})
        assert %{"message" => "Hello, Ada!", "request_id" => _} = JSON.decode!(body)
      end

      test "Function URL request", %{rt: rt} do
        event = %{
          "version" => "2.0",
          "rawPath" => "/",
          "rawQueryString" => "name=Bob",
          "queryStringParameters" => %{"name" => "Bob"},
          "headers" => %{"host" => "example.lambda-url.#{a.region}.on.aws"},
          "requestContext" => %{"http" => %{"method" => "GET", "path" => "/"}}
        }

        assert {:ok, %{body: body}} = LocalRuntime.invoke(rt, event)
        assert %{"statusCode" => 200, "body" => inner} = JSON.decode!(body)
        assert %{"message" => "Hello, Bob!"} = JSON.decode!(inner)
      end
    end
    """
  end

  defp readme(a) do
    """
    # #{a.module}

    An Elixir AWS Lambda function built with [Mayfly](https://elixir-aws-lambda.dev).

    ```bash
    mix lambda.invoke #{a.module}.Handler '{"name":"world"}'   # run locally through the real runtime
    MIX_ENV=prod mix release lambda                          # -> _build/prod/rel/lambda/lambda.zip
    mix lambda.doctor                                        # release config, handler, OTP vs layer
    ```

    The release is built for the public Mayfly ERTS layer (`mayfly-erlang-#{a.otp}-#{a.arch}`), so the
    zip contains only BEAM files and builds on any OS. Your toolchain must use the layer's exact
    OTP version: `.tool-versions` pins Erlang #{a.otp_full} / Elixir #{a.elixir} (`mise install` or asdf).
    #{if a.layer_arn, do: "\nLayer for #{a.region}/#{a.arch}: `#{a.layer_arn}`\n", else: ""}
    #{readme_deploy(a)}
    Guides: https://elixir-aws-lambda.dev/docs/
    """
  end

  defp readme_deploy(%{iac: "none"} = a) do
    """
    ## Deploy

    ```bash
    aws lambda create-function --function-name #{a.function_name} \\
      --runtime provided.al2023 --architectures #{a.arch} --handler #{a.module}.Handler \\
      --zip-file fileb://_build/prod/rel/lambda/lambda.zip \\
      --layers #{a.layer_arn || "<layer ARN from https://elixir-aws-lambda.dev/layers/>"} \\
      --role arn:aws:iam::ACCOUNT:role/lambda-role --logging-config LogFormat=JSON
    aws lambda invoke --function-name #{a.function_name} --cli-binary-format raw-in-base64-out \\
      --payload '{"name":"world"}' out.json && cat out.json
    ```

    Re-run `mix lambda.new` with `--iac sam|terraform|cdk` for an infrastructure-as-code setup.
    """
  end

  defp readme_deploy(%{iac: "sam"} = a) do
    """
    ## Deploy with AWS SAM

    ```bash
    sam build        # runs `mix release lambda` via the Makefile (no Docker)
    sam deploy       # first time: sam deploy --guided, or rely on samconfig.toml
    aws lambda invoke --function-name #{a.function_name} --cli-binary-format raw-in-base64-out --payload '{"name":"world"}' out.json
    sam delete       # tear down
    ```

    `template.yaml` resolves the Mayfly layer for the deployment region from its `Mappings`
    (parameter `OtpMajor` must match the OTP your release was built with).
    """
  end

  defp readme_deploy(%{iac: "terraform"} = a) do
    """
    ## Deploy with Terraform

    ```bash
    MIX_ENV=prod mix release lambda
    cd infra
    terraform init && terraform apply -auto-approve
    aws lambda invoke --function-name #{a.function_name} --cli-binary-format raw-in-base64-out --payload '{"name":"world"}' out.json
    terraform destroy -auto-approve
    ```

    `infra/locals.tf` holds the Mayfly layer ARNs per region; `var.layer_arn` overrides them.
    """
  end

  defp readme_deploy(%{iac: "cdk"} = a) do
    """
    ## Deploy with AWS CDK

    ```bash
    MIX_ENV=prod mix release lambda
    cd infra
    npm install
    npx cdk bootstrap            # once per account/region
    npx cdk deploy --require-approval never
    aws lambda invoke --function-name #{a.function_name} --cli-binary-format raw-in-base64-out --payload '{"name":"world"}' out.json
    npx cdk destroy --force
    ```

    `infra/lib/mayfly-function.ts` is a `MayflyFunction` construct (a `lambda.Function` with the
    right runtime, architecture, layer, JSON logs and tracing); `MayflyFunction.layerArn/3` resolves ARNs.
    """
  end

  # -- IaC files -----------------------------------------------------------------------

  defp iac_files(%{iac: "none"}), do: []

  defp iac_files(a) do
    dir = Path.join(templates_dir(), a.iac)

    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn file ->
      rel = Path.relative_to(file, dir)
      # SAM needs template, samconfig and Makefile in the project root; the others live in infra/.
      target = if a.iac == "sam", do: rel, else: Path.join("infra", rel)
      {target, render(File.read!(file), a)}
    end)
  end

  @doc false
  def render(content, a) do
    content
    |> String.replace("__FUNCTION_NAME__", a.function_name)
    |> String.replace("__HANDLER__", "#{a.module}.Handler")
    |> String.replace("__ARCH__", a.arch)
    |> String.replace("__OTP__", a.otp)
    |> String.replace("__REGION__", a.region)
    |> String.replace("__STACK_CLASS__", "#{a.module}Stack")
  end

  @doc false
  def templates_dir do
    candidates =
      [Path.expand("templates", File.cwd!())] ++
        case Mix.Project.deps_paths()[:mayfly] do
          nil -> []
          path -> [Path.join(path, "templates")]
        end

    Enum.find(candidates, &File.dir?(Path.join(&1, "sam"))) ||
      Mix.raise(
        "Could not find Mayfly's templates/ directory (looked in #{Enum.join(candidates, ", ")})"
      )
  end

  defp deploy_hint(%{iac: "none"}),
    do:
      "    Deploy: see README.md (aws lambda create-function) or re-run with --iac sam|terraform|cdk.\n"

  defp deploy_hint(%{iac: "sam"}),
    do: "    Deploy: sam build && sam deploy --guided\n"

  defp deploy_hint(%{iac: "terraform"}),
    do: "    Deploy: cd infra && terraform init && terraform apply\n"

  defp deploy_hint(%{iac: "cdk"}), do: "    Deploy: cd infra && npm install && npx cdk deploy\n"
end
