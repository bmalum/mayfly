defmodule Mix.Tasks.Lambda.Build do
  @shortdoc "Builds a Lambda deployment package (zip or container image)"

  @moduledoc """
  Builds the Lambda package for a release configured with `Mayfly.Release`:
  a `lambda.zip` (copied to `--outdir`) or, with `--image`, a container image
  for Lambda's image package type.

      mix lambda.build                       # native: MIX_ENV=prod mix release lambda
      mix lambda.build --docker              # inside Amazon Linux 2023, x86_64
      mix lambda.build --docker --arch arm64
      mix lambda.build --release other --env staging --outdir ./deploy
      mix lambda.build --image --arch arm64  # container image my_app-lambda:latest
      mix lambda.build --image --arch arm64 --push 123456789012.dkr.ecr.eu-central-1.amazonaws.com/my-app

  Without `--docker`, the release is built on this machine. That is correct
  when the release uses the Mayfly ERTS layer (`mayfly: [layer: true]`) or when
  you are on Amazon Linux 2023 with the target architecture; otherwise use
  `--docker` so the bundled ERTS matches Lambda.

  ## Container images (`--image`)

  The release is built inside the Amazon Linux 2023 build container (as with
  `--docker`) and copied into an image based on
  `public.ecr.aws/lambda/provided:al2023`, at `/var/task`, with the
  function handler as the image `CMD`. The base image's entrypoint runs the
  Runtime Interface Emulator when `AWS_LAMBDA_RUNTIME_API` is unset, so the
  image can be invoked locally:

      finch run --rm --platform linux/arm64 -p 9000:8080 my_app-lambda:latest
      curl -d '{"name":"x"}' localhost:9000/2015-03-31/functions/function/invocations

  Releases with bundled ERTS and releases built for the Mayfly layer both
  work; in the latter case `/opt/erlang` from the build image is copied into
  the function image. Native dependencies (NIFs) are compiled in the build
  stage, so no layer and no local toolchain are needed. Put a
  `lambda.image.Dockerfile` in your project to customise the image (system
  packages, extra files); it receives the build args `RELEASE_DIR` (release
  directory relative to the project), `BUILD_IMAGE` and `HANDLER`.

  `--push REPO_URI` logs in to ECR with the AWS CLI, tags and pushes, and
  prints the `aws lambda create-function --package-type Image` command with
  the image digest.

  ## Options

      --release, -r    Release name (default: first release in mix.exs)
      --env, -e        MIX_ENV for the release (default: prod)
      --outdir, -o     Where to copy lambda.zip (default: current directory)
      --docker, -d     Build inside a container from lambda.Dockerfile (docker or finch)
      --arch, -a       x86_64 (default) or arm64, Docker and image builds
      --image          Build a container image instead of a zip (implies --docker)
      --tag, -t        Image name:tag (default: <app>-lambda:latest)
      --push           ECR repository URI to push the image to
      --build-image    Tag of the Amazon Linux build image (default: mayfly-build-<app>)
  """

  use Mix.Task

  @switches [
    release: :string,
    env: :string,
    outdir: :string,
    docker: :boolean,
    arch: :string,
    image: :boolean,
    tag: :string,
    push: :string,
    build_image: :string,
    help: :boolean
  ]
  @aliases [r: :release, e: :env, o: :outdir, d: :docker, a: :arch, t: :tag, h: :help]
  @base_image "public.ecr.aws/lambda/provided:al2023"
  @archs %{"x86_64" => "linux/amd64", "arm64" => "linux/arm64"}
  @workdir "/mnt/code"

  @impl true
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid options: #{inspect(invalid)}. See `mix help lambda.build`.")

      opts[:arch] && not Map.has_key?(@archs, opts[:arch]) ->
        Mix.raise("--arch must be x86_64 or arm64")

      opts[:push] && !opts[:image] ->
        Mix.raise("--push requires --image")

      opts[:image] ->
        build_image(with_defaults(opts))

      true ->
        build(with_defaults(opts))
    end
  end

  defp with_defaults(opts) do
    opts
    |> Keyword.put_new(:env, "prod")
    |> Keyword.put_new(:arch, "x86_64")
    |> Keyword.put_new(:outdir, ".")
    |> Keyword.put_new_lazy(:release, &default_release/0)
    |> then(fn o -> if o[:image], do: Keyword.put(o, :docker, true), else: o end)
    |> Keyword.put_new_lazy(:tag, fn -> "#{Mix.Project.config()[:app]}-lambda:latest" end)
  end

  defp default_release do
    case Mix.Project.config()[:releases] do
      [{name, _} | _] ->
        Atom.to_string(name)

      _ ->
        Mix.raise(
          "No releases configured. Add `releases: [lambda: [steps: [&Mayfly.Release.prepare/1, :assemble, &Mayfly.Release.bootstrap/1, &Mayfly.Release.zip/1], mayfly: [handler: ...]]]` to mix.exs."
        )
    end
  end

  defp build(opts) do
    if opts[:docker], do: docker_release(opts), else: native_release(opts)

    zip = Path.join(release_path(opts), "lambda.zip")

    File.regular?(zip) ||
      Mix.raise("Expected #{zip} to exist – does the release include Mayfly.Release.zip/1?")

    File.mkdir_p!(opts[:outdir])
    target = Path.join(opts[:outdir], "lambda.zip")
    File.cp!(zip, target)

    Mix.shell().info([
      :green,
      "✓ ",
      :reset,
      "#{target} (#{div(File.stat!(target).size, 1024)} KiB)"
    ])

    Mix.shell().info("  runtime provided.al2023 · handler: set to your Mayfly.Handler module")
  end

  # -- container image -----------------------------------------------------------------

  defp build_image(opts) do
    docker_release(opts)

    cli = container_cli()
    platform = Map.fetch!(@archs, opts[:arch])
    release_dir = release_path(opts)
    handler = release_handler(opts[:release])
    build_image = build_image_tag()
    bundled_erts? = Path.wildcard(Path.join(release_dir, "erts-*")) != []

    {dockerfile, context, args} =
      case File.exists?("lambda.image.Dockerfile") do
        true ->
          {"lambda.image.Dockerfile", File.cwd!(),
           [
             "--build-arg",
             "RELEASE_DIR=#{Path.relative_to(release_dir, File.cwd!())}",
             "--build-arg",
             "BUILD_IMAGE=#{build_image}",
             "--build-arg",
             "HANDLER=#{handler}"
           ]}

        false ->
          File.write!(
            Path.join(release_dir, "lambda.image.Dockerfile"),
            image_dockerfile(handler, build_image, bundled_erts?)
          )

          File.write!(
            Path.join(release_dir, ".dockerignore"),
            "lambda.zip\nlambda.image.Dockerfile\n"
          )

          {Path.join(release_dir, "lambda.image.Dockerfile"), release_dir, []}
      end

    run!(
      cli,
      ["build", "--platform", platform, "-t", opts[:tag], "-f", dockerfile] ++
        no_attestations(cli) ++ args ++ [context]
    )

    Mix.shell().info([
      :green,
      "✓ ",
      :reset,
      "image #{opts[:tag]} (#{opts[:arch]}, handler #{handler})"
    ])

    port = 9000

    Mix.shell().info("""
      run locally (Runtime Interface Emulator is in the base image):
        #{cli} run --rm --platform #{platform} -p #{port}:8080 #{opts[:tag]}
        curl -d '{}' http://localhost:#{port}/2015-03-31/functions/function/invocations
    """)

    if repo = opts[:push], do: push_image(cli, opts, repo, handler)
  end

  @doc false
  @spec image_dockerfile(String.t(), String.t(), boolean()) :: String.t()
  def image_dockerfile(handler, build_image, bundled_erts?) do
    erts =
      if bundled_erts?,
        do: "",
        else:
          "# Release built for the Mayfly layer: take ERTS from the build image.\nCOPY --from=#{build_image} /opt/erlang /opt/erlang\n"

    """
    # Generated by mix lambda.build --image. Override with lambda.image.Dockerfile in your project.
    FROM #{@base_image}
    #{erts}COPY . ${LAMBDA_TASK_ROOT}/
    # The base entrypoint runs /var/runtime/bootstrap (through aws-lambda-rie when
    # AWS_LAMBDA_RUNTIME_API is unset) and exports its single argument as _HANDLER.
    RUN ln -sf ${LAMBDA_TASK_ROOT}/bootstrap /var/runtime/bootstrap
    CMD ["#{handler}"]
    """
  end

  # BuildKit wraps single-platform images in an OCI index with provenance/SBOM
  # attestation manifests, which Lambda rejects ("image manifest, config or layer
  # media type ... is not supported"). Turn them off where the CLI knows the flags.
  defp no_attestations(cli) do
    {help, _} = System.cmd(cli, ["build", "--help"], stderr_to_stdout: true)
    for flag <- ["--provenance", "--sbom"], String.contains?(help, flag), do: "#{flag}=false"
  rescue
    ErlangError -> []
  end

  defp push_image(cli, opts, repo, handler) do
    {registry, region} = parse_ecr(repo)
    remote = "#{repo}:#{tag_of(opts[:tag])}"

    Mix.shell().info([
      :cyan,
      "$ aws ecr get-login-password | #{cli} login --username AWS --password-stdin #{registry}"
    ])

    # System.cmd cannot feed stdin; let the shell do the pipe. Both names are
    # validated (region by the ECR regex, cli is docker/finch or CONTAINER_CLI).
    login =
      "aws ecr get-login-password --region #{region} | #{cli} login --username AWS --password-stdin #{registry}"

    case System.cmd("sh", ["-c", login], stderr_to_stdout: true) do
      {out, 0} -> Mix.shell().info(String.trim(out))
      {out, status} -> Mix.raise("ECR login failed (#{status}): #{out}")
    end

    run!(cli, ["tag", opts[:tag], remote])
    run!(cli, ["push", remote])

    digest =
      aws!([
        "ecr",
        "describe-images",
        "--region",
        region,
        "--repository-name",
        repo |> String.split("/", parts: 2) |> List.last(),
        "--image-ids",
        "imageTag=#{tag_of(opts[:tag])}",
        "--query",
        "imageDetails[0].imageDigest",
        "--output",
        "text"
      ])
      |> String.trim()

    Mix.shell().info([:green, "✓ ", :reset, "pushed #{remote} (#{digest})"])

    Mix.shell().info("""
      create the function (no --runtime, no --layers for images):
        aws lambda create-function --function-name my-function --package-type Image \\
          --code ImageUri=#{repo}@#{digest} --architectures #{opts[:arch]} \\
          --role arn:aws:iam::ACCOUNT:role/lambda-role --logging-config LogFormat=JSON
      override the handler per function with --image-config Command=#{handler}
    """)
  end

  @doc false
  @spec parse_ecr(String.t()) :: {String.t(), String.t()}
  def parse_ecr(repo) do
    case Regex.run(~r/^(\d{12}\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com(?:\.cn)?)\/[^:@]+$/, repo) do
      [_, registry, region] ->
        {registry, region}

      _ ->
        Mix.raise(
          "--push expects an ECR repository URI like 123456789012.dkr.ecr.eu-central-1.amazonaws.com/my-app, got #{repo}"
        )
    end
  end

  defp tag_of(name_tag) do
    case String.split(name_tag, ":") do
      [_name, tag] -> tag
      _ -> "latest"
    end
  end

  defp aws!(args) do
    case System.cmd("aws", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, status} -> Mix.raise("`aws #{Enum.join(args, " ")}` failed (#{status}): #{out}")
    end
  rescue
    e in ErlangError -> Mix.raise("--push needs the AWS CLI on PATH: #{Exception.message(e)}")
  end

  defp release_handler(release) do
    releases = Mix.Project.config()[:releases] || []
    mayfly = releases |> Keyword.get(String.to_atom(release), []) |> Keyword.get(:mayfly, [])

    case Keyword.get(mayfly, :handler) do
      nil -> Mix.raise("releases: #{release}: missing mayfly: [handler: ...]")
      module when is_atom(module) -> inspect(module)
      string when is_binary(string) -> string
    end
  end

  defp build_image_tag, do: "mayfly-build-#{Mix.Project.config()[:app]}"

  # -- zip -----------------------------------------------------------------------------

  defp native_release(opts) do
    run!("mix", ["release", opts[:release], "--overwrite"], env: [{"MIX_ENV", opts[:env]}])
  end

  defp docker_release(opts) do
    image = opts[:build_image] || build_image_tag()
    platform = Map.fetch!(@archs, opts[:arch])
    cli = container_cli()
    extra_mounts = path_dep_mounts()

    dockerfile = dockerfile()
    # The Dockerfile copies nothing from the context, so use its own directory:
    # small, and its .dockerignore applies.
    run!(cli, [
      "build",
      "--platform",
      platform,
      "-t",
      image,
      "-f",
      dockerfile,
      Path.dirname(dockerfile)
    ])

    run!(
      cli,
      [
        "run",
        "--rm",
        "--platform",
        platform,
        "-v",
        "#{File.cwd!()}:#{@workdir}",
        "-w",
        @workdir,
        "-e",
        "MIX_ENV=#{opts[:env]}",
        "-e",
        "MIX_BUILD_PATH=#{@workdir}/#{docker_build_dir(opts)}"
      ] ++
        extra_mounts ++
        [
          image,
          "sh",
          "-c",
          "mix deps.get && mix release #{opts[:release]} --overwrite"
        ]
    )
  end

  # `path:` dependencies outside the project directory are not visible inside
  # the container; mount them read-only at the same absolute path so mix.exs
  # resolves them unchanged. Common during development of Mayfly itself.
  defp path_dep_mounts do
    cwd = File.cwd!()

    for {_app, path} <- Mix.Project.deps_paths(),
        expanded = Path.expand(path),
        not String.starts_with?(expanded, cwd <> "/"),
        expanded != cwd,
        File.dir?(expanded) do
      ["-v", "#{expanded}:#{expanded}:ro"]
    end
    |> List.flatten()
  end

  # Docker artefacts live in their own build dir so they never mix with host builds.
  defp docker_build_dir(opts), do: "_build/docker-#{opts[:arch]}-#{opts[:env]}"

  defp release_path(opts) do
    base =
      if opts[:docker],
        do: Path.join(File.cwd!(), docker_build_dir(opts)),
        else: Path.join(Mix.Project.build_path() |> Path.dirname(), opts[:env])

    Path.join([base, "rel", opts[:release]])
  end

  # `docker`, or `finch` (Docker-compatible CLI) when docker is not installed.
  # Override with CONTAINER_CLI.
  defp container_cli do
    System.get_env("CONTAINER_CLI") ||
      Enum.find(["docker", "finch"], &System.find_executable/1) ||
      Mix.raise("--docker needs docker or finch on PATH (or CONTAINER_CLI=...)")
  end

  defp dockerfile do
    candidates =
      ["lambda.Dockerfile"] ++
        case Mix.Project.deps_paths()[:mayfly] do
          nil -> []
          path -> [Path.join(path, "lambda.Dockerfile")]
        end

    Enum.find(candidates, &File.exists?/1) ||
      Mix.raise("No lambda.Dockerfile found in the project or in the mayfly dependency")
  end

  defp run!(cmd, args, opts \\ []) do
    Mix.shell().info([:cyan, "$ #{cmd} #{Enum.join(args, " ")}"])

    case System.cmd(cmd, args, [into: IO.stream(), stderr_to_stdout: true] ++ opts) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("`#{cmd}` failed with status #{status}")
    end
  rescue
    e in ErlangError -> Mix.raise("Could not run #{cmd}: #{Exception.message(e)}")
  end
end
