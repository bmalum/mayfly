defmodule Mix.Tasks.Lambda.Build do
  @moduledoc """
  A Mix task for building AWS Lambda deployment packages for Elixir applications.

  This task creates a deployment package for AWS Lambda, including:
  - Building a release using `mix release`
  - Creating a bootstrap script
  - Optionally building in a Docker container
  - Optionally creating a ZIP archive for deployment

  ## Usage

      mix lambda.build [options]

  ## Options

      --zip, -z      - Create a ZIP file for deployment
      --outdir, -o   - Specify the output directory (default: current directory)
      --docker, -d   - Build using Docker (useful for cross-platform compatibility)
      --help, -h     - Print this help message

  ## Examples

      # Build a release
      mix lambda.build

      # Build a release and create a ZIP file
      mix lambda.build --zip

      # Build using Docker and create a ZIP file
      mix lambda.build --docker --zip

      # Specify an output directory
      mix lambda.build --zip --outdir ./deploy
  """
  use Mix.Task
  require Logger

  @switches [
    zip: :boolean,
    outdir: :string,
    docker: :boolean,
    help: :boolean
  ]

  @aliases [
    z: :zip,
    o: :outdir,
    d: :docker,
    h: :help
  ]

  @doc """
  Runs the Lambda build task.

  This is the main entry point for the mix task, orchestrating the build process.
  """
  @spec run(list(String.t())) :: any()
  def run(args) do
    with {:ok, opts} <- parse_and_validate_args(args),
         old_mix_env <- setup_environment(),
         :ok <- build_release(),
         {:ok, bootstrap_path} <- create_bootstrap(opts),
         :ok <- handle_docker_build(opts, bootstrap_path),
         :ok <- create_zip_archive(opts, bootstrap_path),
         :ok <- restore_environment(old_mix_env) do
      print_summary(opts)
    else
      {:halt, :help} ->
        :ok

      {:error, reason} ->
        Logger.error("Build failed: #{reason}")
        exit({:shutdown, 1})
    end
  end

  @doc """
  Parses and validates command line arguments.

  Returns `{:ok, opts}` if successful, `{:halt, :help}` if help was requested,
  or `{:error, reason}` if validation fails.
  """
  @spec parse_and_validate_args(list(String.t())) ::
    {:ok, keyword()} | {:halt, :help} | {:error, String.t()}
  def parse_and_validate_args(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      Keyword.get(opts, :help) ->
        print_help()
        {:halt, :help}

      not Enum.empty?(invalid) ->
        {:error, "Invalid options: #{inspect invalid}"}

      true ->
        {:ok, opts}
    end
  end

  @doc """
  Sets up the build environment.

  Sets MIX_ENV to "lambda" and returns the original value.
  """
  @spec setup_environment() :: String.t() | nil
  def setup_environment do
    old_mix_env = System.get_env("MIX_ENV")
    System.put_env("MIX_ENV", "lambda")
    Logger.debug("Set MIX_ENV to lambda (was: #{old_mix_env || "not set"})")
    old_mix_env
  end

  @doc """
  Builds the release using mix release.

  Returns `:ok` if successful.
  """
  @spec build_release() :: :ok | {:error, String.t()}
  def build_release do
    IO.write("#{IO.ANSI.cyan()}Building release...#{IO.ANSI.reset()} ")
    # Use System.cmd to run the release command directly, which respects the MIX_ENV
    case run_command("mix", ["release", "--force", "--overwrite"]) do
      {:ok, _output} ->
        IO.puts("#{IO.ANSI.green()}done#{IO.ANSI.reset()}")
        :ok
      {:error, reason} ->
        IO.puts("#{IO.ANSI.red()}failed#{IO.ANSI.reset()}")
        {:error, reason}
    end
  end

  @doc """
  Creates the bootstrap file.

  Returns `{:ok, bootstrap_path}` if successful.
  """
  @spec create_bootstrap(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def create_bootstrap(_opts) do
    IO.write("#{IO.ANSI.cyan()}Creating bootstrap script...#{IO.ANSI.reset()} ")

    wd = File.cwd!()
    bootstrap_path = Path.join(wd, "bootstrap")
    project_name = Mix.Project.get().project()[:app]

    case File.write(bootstrap_path, bootstrap_content(project_name)) do
      :ok ->
        case File.chmod(bootstrap_path, 0o755) do
          :ok ->
            IO.puts("#{IO.ANSI.green()}done#{IO.ANSI.reset()}")
            {:ok, bootstrap_path}
          {:error, reason} ->
            {:error, "Failed to set permissions on bootstrap file: #{inspect(reason)}"}
        end
      {:error, reason} ->
        {:error, "Failed to write bootstrap file: #{inspect(reason)}"}
    end
  end

  @doc """
  Handles Docker build if requested.

  Returns `:ok` if successful or if Docker build was not requested.
  """
  @spec handle_docker_build(keyword(), String.t()) :: :ok | {:error, String.t()}
  def handle_docker_build(opts, _bootstrap_path) do
    if Keyword.get(opts, :docker, false) do
      IO.puts("#{IO.ANSI.cyan()}Building with Docker...#{IO.ANSI.reset()}")

      wd = File.cwd!()

      with {:ok, _} <- run_command("docker", ["build", "-t", "elbc", "-f", "./deps/aws_lambda/Dockerfile", "."]),
           {:ok, _} <- run_command("docker", ["run", "--rm", "-v", "#{wd}:/mnt/code", "elbc:latest", "mix", "release"]) do
        IO.puts("#{IO.ANSI.green()}Docker build completed successfully#{IO.ANSI.reset()}")
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @doc """
  Creates a ZIP archive if requested.

  Returns `:ok` if successful or if ZIP creation was not requested.
  """
  @spec create_zip_archive(keyword(), String.t()) :: :ok | {:error, String.t()}
  def create_zip_archive(opts, _bootstrap_path) do
    if Keyword.get(opts, :zip, false) do
      IO.write("#{IO.ANSI.cyan()}Creating ZIP archive...#{IO.ANSI.reset()} ")

      # Get the output directory if specified, or use the current directory
      outdir = Keyword.get(opts, :outdir, ".")
      # Ensure the output directory exists
      File.mkdir_p!(outdir)

      # Create the zip file path
      zip_path = Path.join(outdir, "lambda.zip")

      filelist_to_zip = ["./_build/lambda", "bootstrap"]
      params = ["-r", "-9", zip_path] ++ filelist_to_zip

      case run_command("zip", params) do
        {:ok, _} ->
          IO.puts("#{IO.ANSI.green()}done#{IO.ANSI.reset()}")
          :ok
        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  @doc """
  Restores the original environment.

  Returns `:ok` if successful.
  """
  @spec restore_environment(String.t() | nil) :: :ok
  def restore_environment(old_mix_env) do
    if old_mix_env == nil do
      System.delete_env("MIX_ENV")
    else
      System.put_env("MIX_ENV", old_mix_env)
    end

    :ok
  end

  @doc """
  Prints a summary of the build process.
  """
  @spec print_summary(keyword()) :: :ok
  def print_summary(opts) do
    IO.puts("\n#{IO.ANSI.green()}✓ Lambda build completed successfully#{IO.ANSI.reset()}")

    if Keyword.get(opts, :docker, false) do
      IO.puts("  #{IO.ANSI.cyan()}•#{IO.ANSI.reset()} Built using Docker")
    end

    if Keyword.get(opts, :zip, false) do
      # Get the output directory if specified, or use the current directory
      outdir = Keyword.get(opts, :outdir, ".")
      # Create the zip file path
      zip_path = Path.join(outdir, "lambda.zip")
      IO.puts("  #{IO.ANSI.cyan()}•#{IO.ANSI.reset()} Created ZIP archive: #{zip_path}")
    end

    IO.puts("\nYou can now deploy your Lambda function to AWS.")
    :ok
  end

  @doc """
  Prints help information.
  """
  @spec print_help() :: :ok
  def print_help do
    IO.puts(@moduledoc)
    :ok
  end

  @doc """
  Runs a system command and handles the result.

  Returns `{:ok, output}` if successful, or `{:error, reason}` if the command fails.
  """
  @spec run_command(String.t(), list(String.t())) :: {:ok, String.t()} | {:error, String.t()}
  def run_command(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {output, 0} ->
        Logger.debug("Command succeeded: #{cmd} #{Enum.join(args, " ")}")
        {:ok, output}

      {output, status} ->
        {:error, "Command '#{cmd} #{Enum.join(args, " ")}' failed with status #{status}:\n#{output}"}
    end
  end

  @doc """
  Generates the content for the bootstrap script.
  """
  @spec bootstrap_content(atom()) :: String.t()
  def bootstrap_content(project_name) do
    """
    #!/bin/sh
    set -euo pipefail
    export ELIXIR_ERL_OPTIONS="+fnu"
    _build/lambda/rel/#{project_name}/bin/#{project_name} start
    """
  end
end
