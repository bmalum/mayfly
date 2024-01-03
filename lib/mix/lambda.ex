defmodule Mix.Tasks.Lambda.Build do
  use Mix.Task

  def run(args) do
    parsed = IO.inspect(OptionParser.parse(args, strict: [zip: :boolean, outdir: :string]))
    IO.inspect(parsed, label: "Received args")

    case parsed do
      {[zip: true], _, _} -> IO.puts("ZIP ZIP ZIP")
    end

    # Release
    Mix.Task.run("release", ["--force", "--overwrite"])

    # write Bootstrap File
    params = []
    wd = File.cwd!()
    bootstrap_path = wd <> "/bootstrap"
    File.write(bootstrap_path, EEx.eval_string(bootstrap(), params))
    filelist_to_zip = [~c"./_build", ~c"bootstrap"]
    # chmod bootstrap to 755
    File.chmod(bootstrap_path, 775)
    # zip everything
    :zip.create("lambda.zip", filelist_to_zip, cwd: wd)
    # outputs
  end

  defp bootstrap do
    "
    #!/bin/sh
    set -euo pipefail
    export ELIXIR_ERL_OPTIONS=\"+fnu\"
    _build/dev/rel/aws_lambda/bin/aws_lambda start
    "
  end
end
