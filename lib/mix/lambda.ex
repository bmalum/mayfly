defmodule Mix.Tasks.Lambda.Build do
  use Mix.Task

  def run(args) do
    {parsed, other, err} = IO.inspect(OptionParser.parse(args, strict: [zip: :boolean, outdir: :string, docker: :boolean]))
    IO.inspect(parsed, label: "Received args")

    old_mix_env = System.get_env("MIX_ENV")
    System.put_env("MIX_ENV", "lambda")
    System.get_env("MIX_ENV") |> IO.inspect

        # Release
    Mix.Task.run("release", ["--force", "--overwrite"])

    # write Bootstrap File
    params = []
    wd = File.cwd!()
    bootstrap_path = wd <> "/bootstrap"
    project_name = Mix.Project.get.project[:app]

    File.write(bootstrap_path, EEx.eval_string(bootstrap(project_name), params))
    # chmod bootstrap to 755

    case Keyword.get(parsed, :docker) do
      true -> System.cwd!() |> IO.inspect 
              System.cmd("docker", ["build", "-t", "elbc", "-f", "./deps/aws_lambda/Dockerfile", "."]) |> IO.inspect 
              System.cmd("docker", ["run", "--rm", "-v", "#{wd}:/mnt/code", "elbc:latest",  "mix", "lambda.build"])
      _ -> nil 
    end

    File.chmod(bootstrap_path, 775)


    case Keyword.get(parsed, :zip) do
      true -> filelist_to_zip = ["./_build/lambda", "bootstrap"]
              # zip everything
              IO.puts("Creating ZIP Archive")
              params = ["-r", "-9", "lambda.zip"] ++ filelist_to_zip 
              #:zip.create("lambda.zip", filelist_to_zip, cwd: wd)  
              System.cmd("zip", params )
      _ -> nil 
    end

    if old_mix_env == nil do 
      System.delete_env("MIX_ENV")
    else
      System.put_env("MIX_ENV", old_mix_env)
    end

    # outputs
  end

  defp bootstrap(project_name) do
"#!/bin/sh
set -euo pipefail
export ELIXIR_ERL_OPTIONS=\"+fnu\"
_build/lambda/rel/#{project_name}/bin/#{project_name} start
"
  end
end
