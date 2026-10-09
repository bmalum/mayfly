defmodule Mayfly.LogFormatterTest do
  use ExUnit.Case, async: true

  alias Mayfly.LogFormatter

  defp format(level, msg, meta) do
    event = %{
      level: level,
      msg: msg,
      meta: Map.merge(%{time: 1_758_956_400_123_456, pid: self()}, meta)
    }

    LogFormatter.format(event, %{})
    |> IO.iodata_to_binary()
    |> String.trim_trailing("\n")
    |> JSON.decode!()
  end

  test "emits the Lambda JSON shape with request and tenant ids" do
    json =
      format(:info, {:string, "hello"}, %{request_id: "r-1", tenant_id: "blue", custom: :thing})

    assert json == %{
             "timestamp" => "2025-09-27T07:00:00.123Z",
             "level" => "INFO",
             "message" => "hello",
             "requestId" => "r-1",
             "tenantId" => "blue",
             "custom" => "thing"
           }
  end

  test "handles format/args and reports" do
    assert %{"message" => "a=1"} = format(:error, {~c"a=~p", [1]}, %{})
    assert %{"message" => msg} = format(:warning, {:report, %{k: :v}}, %{})
    assert msg =~ "k: :v"
  end

  test "each line ends with a newline" do
    out =
      LogFormatter.format(%{level: :info, msg: {:string, "x"}, meta: %{}}, %{})
      |> IO.iodata_to_binary()

    assert String.ends_with?(out, "}\n")
  end
end

defmodule Mayfly.BootTest do
  # Mutates global Logger config.
  use ExUnit.Case, async: false

  test "configure_logger applies LOGLEVEL and AWS_LAMBDA_LOG_FORMAT" do
    original = Logger.level()
    {:ok, %{formatter: original_formatter}} = :logger.get_handler_config(:default)

    try do
      System.put_env("LOGLEVEL", "error")
      System.put_env("AWS_LAMBDA_LOG_FORMAT", "JSON")
      Mayfly.Boot.configure_logger()

      assert Logger.level() == :error
      assert {:ok, %{formatter: {Mayfly.LogFormatter, _}}} = :logger.get_handler_config(:default)
    after
      System.delete_env("LOGLEVEL")
      System.delete_env("AWS_LAMBDA_LOG_FORMAT")
      Logger.configure(level: original)
      :logger.update_handler_config(:default, :formatter, original_formatter)
    end
  end
end

defmodule Mayfly.ReleaseTest do
  use ExUnit.Case, async: true

  alias Mayfly.Release

  test "bootstrap_content/3 bundled ERTS" do
    c = Release.bootstrap_content(:lambda, MyApp.Handler, false)
    assert c =~ "#!/bin/bash"
    assert c =~ ~s(export RELEASE_TMP="${RELEASE_TMP:-/tmp}")
    assert c =~ ~s(export RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-none}")
    assert c =~ "+S 1:1"
    assert c =~ "AWS_LAMBDA_MAX_CONCURRENCY"
    assert c =~ ~s(export _HANDLER="${_HANDLER:-MyApp.Handler}")
    assert c =~ ~s|exec "$LAMBDA_TASK_ROOT/bin/lambda" eval "Mayfly.Boot.main()"|
    refute c =~ "/opt/erlang"
  end

  test "bootstrap_content/3 with layer prepends the layer PATH and accepts string handlers" do
    c = Release.bootstrap_content(:app, "MyApp.Legacy.handle", true)
    assert c =~ ~s(export PATH="$MAYFLY_ERTS/bin:$PATH")
    assert c =~ "erts-$ERTS_VSN"
    assert c =~ ~s(_HANDLER:-MyApp.Legacy.handle})
  end

  @tag :tmp_dir
  test "bootstrap/1 and zip/1 steps operate on a release struct", %{tmp_dir: tmp} do
    File.mkdir_p!(Path.join(tmp, "bin"))
    File.write!(Path.join(tmp, "bin/app"), "#!/bin/sh\n")

    release = %Mix.Release{
      name: :app,
      version: "1.0.0",
      path: tmp,
      version_path: Path.join(tmp, "releases/1.0.0"),
      applications: %{},
      boot_scripts: %{},
      erts_source: nil,
      erts_version: ~c"15",
      config_providers: [],
      options: [mayfly: [handler: MyApp.Handler]],
      overlays: [],
      steps: []
    }

    Mix.shell(Mix.Shell.Process)

    try do
      assert %Mix.Release{} = release |> Release.bootstrap() |> Release.zip()
    after
      Mix.shell(Mix.Shell.IO)
    end

    assert File.stat!(Path.join(tmp, "bootstrap")).mode |> Bitwise.band(0o111) != 0
    {:ok, entries} = :zip.list_dir(Path.join(tmp, "lambda.zip") |> String.to_charlist())
    names = for {:zip_file, n, _, _, _, _} <- entries, do: List.to_string(n)
    assert "bootstrap" in names and "bin/app" in names
    refute "lambda.zip" in names
  end

  test "prepare/1 applies defaults and honours layer" do
    base = %Mix.Release{
      name: :app,
      version: "1",
      path: "/tmp/x",
      version_path: "/tmp/x/releases/1",
      applications: %{},
      boot_scripts: %{},
      erts_source: ~c"/erts",
      erts_version: ~c"15",
      config_providers: [],
      options: [mayfly: [handler: H]],
      overlays: [],
      steps: []
    }

    prepared = Release.prepare(base)
    assert prepared.options[:strip_beams] == true
    assert prepared.options[:include_executables_for] == [:unix]
    assert prepared.erts_source == ~c"/erts"

    assert %{erts_source: nil} =
             Release.prepare(%{base | options: [mayfly: [handler: H, layer: true]]})

    assert_raise KeyError, fn -> Release.prepare(%{base | options: []}) end
  end
end

defmodule Mix.Tasks.LambdaTasksTest do
  # Swaps the global Mix shell.
  use ExUnit.Case, async: false

  test "lambda.build rejects bad options" do
    assert_raise Mix.Error, ~r/Invalid options/, fn -> Mix.Tasks.Lambda.Build.run(["--bogus"]) end

    assert_raise Mix.Error, ~r/--arch/, fn ->
      Mix.Tasks.Lambda.Build.run(["--docker", "--arch", "mips"])
    end
  end

  test "lambda.build --help prints usage" do
    Mix.shell(Mix.Shell.Process)

    try do
      Mix.Tasks.Lambda.Build.run(["--help"])
      assert_received {:mix_shell, :info, [help]}
      assert help =~ "mix lambda.build"
    after
      Mix.shell(Mix.Shell.IO)
    end
  end

  test "lambda.invoke runs a handler end to end" do
    Mix.shell(Mix.Shell.Process)

    try do
      Mix.Tasks.Lambda.Invoke.run(["Mayfly.Test.Handlers.Echo", ~s({"n":1})])
      assert_received {:mix_shell, :info, [out]}
      assert out =~ ~s("n" => 1)
    after
      Mix.shell(Mix.Shell.IO)
    end
  end

  test "lambda.invoke exits 1 on handler error" do
    Mix.shell(Mix.Shell.Process)

    try do
      assert catch_exit(
               Mix.Tasks.Lambda.Invoke.run(["Mayfly.Test.Handlers.Faulty", ~s({"mode":"raise"})])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :error, [out]}
      assert out =~ "ArgumentError"
    after
      Mix.shell(Mix.Shell.IO)
    end
  end
end

defmodule Mix.Tasks.Lambda.InvokeFixturesTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lambda.Invoke.Fixtures

  test "apigw-v2 wraps the body like a Function URL" do
    {:ok, json} = Fixtures.wrap("apigw-v2", ~s({"a":1}), method: "get", path: "/items")
    event = JSON.decode!(json)
    assert event["version"] == "2.0"
    assert event["rawPath"] == "/items"
    assert event["requestContext"]["http"]["method"] == "GET"
    assert event["body"] == ~s({"a":1})

    assert {:ok, %Mayfly.Events.HTTP.Request{body: %{"a" => 1}, method: "GET"}} =
             Mayfly.Events.decode(event)
  end

  test "every source produces an event Mayfly.Events.decode/1 recognises" do
    for source <- Fixtures.sources() do
      {:ok, json} =
        Fixtures.wrap(
          source,
          ~s({"id":"a1","n":2,"ok":true,"tags":["x"],"m":{"k":"v"},"key":"dir/some file.txt"})
        )

      assert {:ok, struct} = Mayfly.Events.decode(JSON.decode!(json)),
             "source #{source} not recognised"

      assert is_struct(struct)
    end
  end

  test "payload lands where each source carries it" do
    body = ~s({"id":"a1","n":2,"ok":true,"tags":["x"],"m":{"k":"v"},"key":"dir/some file.txt"})

    decoded = %{
      "id" => "a1",
      "n" => 2,
      "ok" => true,
      "tags" => ["x"],
      "m" => %{"k" => "v"},
      "key" => "dir/some file.txt"
    }

    wrap = fn s ->
      {:ok, j} = Fixtures.wrap(s, body)
      {:ok, e} = Mayfly.Events.decode(JSON.decode!(j))
      e
    end

    assert %Mayfly.Events.SQS{records: [%{body: ^decoded}]} = wrap.("sqs")
    assert %Mayfly.Events.SNS{records: [%{message: ^decoded}]} = wrap.("sns")
    assert %Mayfly.Events.Kinesis{records: [%{data: ^decoded}]} = wrap.("kinesis")

    assert %Mayfly.Events.EventBridge{detail: ^decoded, detail_type: "LocalEvent"} =
             wrap.("eventbridge")

    assert %Mayfly.Events.S3{records: [%{key: "dir/some file.txt"}]} = wrap.("s3")

    assert %Mayfly.Events.DynamoDB{
             records: [%{event_name: :insert, new_image: ^decoded, keys: %{"id" => "a1"}}]
           } = wrap.("dynamodb")

    assert %Mayfly.Events.HTTP.Request{version: :v1, body: ^decoded} = wrap.("apigw-v1")
    assert %Mayfly.Events.HTTP.Request{version: :alb, body: ^decoded} = wrap.("alb")
  end

  test "unknown source" do
    assert {:error, msg} = Fixtures.wrap("nope", "{}")
    assert msg =~ "unknown --event nope"
  end
end

defmodule Mix.Tasks.Lambda.DoctorTest do
  # Swaps the global Mix shell.
  use ExUnit.Case, async: false

  test "passes on this project's release configuration" do
    Mix.shell(Mix.Shell.Process)

    try do
      Mix.Tasks.Lambda.Doctor.run([])
      assert_received {:mix_shell, :info, ["\nAll checks passed."]}
    after
      Mix.shell(Mix.Shell.IO)
    end
  end

  test "fails for an unknown release" do
    Mix.shell(Mix.Shell.Process)

    try do
      assert catch_exit(Mix.Tasks.Lambda.Doctor.run(["--release", "nope"])) == {:shutdown, 1}
      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "no release found named nope"
    after
      Mix.shell(Mix.Shell.IO)
    end
  end
end
