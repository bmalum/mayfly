defmodule Mix.Tasks.Lambda.Build do
  @shortdoc "Builds a Lambda deployment package (mix release + zip), optionally in Docker"

  @moduledoc """
  Builds the Lambda package for a release configured with `Mayfly.Release`
  and copies the resulting `lambda.zip` to `--outdir`.

      mix lambda.build                       # native: MIX_ENV=prod mix release lambda
      mix lambda.build --docker              # inside Amazon Linux 2023, x86_64
      mix lambda.build --docker --arch arm64
      mix lambda.build --release other --env staging --outdir ./deploy

  Without `--docker`, the release is built on this machine. That is correct
  when the release uses the Mayfly ERTS layer (`mayfly: [layer: true]`) or when
  you are on Amazon Linux 2023 with the target architecture; otherwise use
  `--docker` so the bundled ERTS matches Lambda.

  ## Options

      --release, -r    Release name (default: first release in mix.exs)
      --env, -e        MIX_ENV for the release (default: prod)
      --outdir, -o     Where to copy lambda.zip (default: current directory)
      --docker, -d     Build inside a container from lambda.Dockerfile (docker or finch)
      --arch, -a       x86_64 (default) or arm64, Docker only
      --image          Docker image tag (default: mayfly-build-<app>)
  """

  use Mix.Task

  @switches [
    release: :string,
    env: :string,
    outdir: :string,
    docker: :boolean,
    arch: :string,
    image: :string,
    help: :boolean
  ]
  @aliases [r: :release, e: :env, o: :outdir, d: :docker, a: :arch, h: :help]
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

  defp native_release(opts) do
    run!("mix", ["release", opts[:release], "--overwrite"], env: [{"MIX_ENV", opts[:env]}])
  end

  defp docker_release(opts) do
    app = Mix.Project.config()[:app]
    image = opts[:image] || "mayfly-build-#{app}"
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
