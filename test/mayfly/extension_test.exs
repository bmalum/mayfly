defmodule Mayfly.ExtensionTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Mayfly.{Extension, LocalRuntime}

  defp start(opts \\ []) do
    rt = start_supervised!({LocalRuntime, []}, id: make_ref())
    test = self()

    {:ok, sup} =
      Mayfly.start_link(
        [
          handler: "Mayfly.Test.Handlers.Echo",
          runtime_api: LocalRuntime.address(rt),
          name: nil,
          extension: true,
          extension_opts: [
            name: nil,
            listener_host: "127.0.0.1",
            halt: fn code -> send(test, {:halted, code}) end
          ]
        ] ++ opts
      )

    ext =
      sup
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {Extension, pid, _, _} -> pid
        _ -> nil
      end)

    {rt, sup, ext}
  end

  test "registers before polling, subscribes to platform telemetry" do
    {rt, _sup, ext} = start()
    id = Extension.identifier(ext)

    assert %{^id => %{name: "mayfly", events: ["INVOKE"]}} =
             LocalRuntime.extensions(rt)

    assert %{^id => sub} = LocalRuntime.telemetry_subscriptions(rt)
    assert sub["schemaVersion"] == "2022-07-01"
    assert sub["types"] == ["platform"]
    assert sub["buffering"] == %{"timeoutMs" => 25, "maxBytes" => 262_144, "maxItems" => 1000}

    assert sub["destination"]["URI"] ==
             "http://127.0.0.1:#{Extension.listener_port(ext)}/telemetry"

    # The runtime still serves invocations normally.
    assert {:ok, %{body: body}} = LocalRuntime.invoke(rt, %{"x" => 1})
    assert JSON.decode!(body) == %{"x" => 1}
  end

  test "telemetry records become :telemetry events with numeric metrics" do
    {rt, _sup, _ext} = start()
    test = self()
    ref = make_ref()

    :telemetry.attach_many(
      {ref, :platform},
      [
        [:mayfly, :platform, :report],
        [:mayfly, :platform, :init_report],
        [:mayfly, :platform, :extension]
      ],
      fn event, measurements, metadata, _ ->
        send(test, {:platform, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({ref, :platform}) end)

    assert [200] =
             LocalRuntime.push_telemetry(rt, [
               %{
                 "time" => "2026-10-09T20:00:00.000Z",
                 "type" => "platform.extension",
                 "record" => %{
                   "name" => "mayfly",
                   "state" => "Ready",
                   "events" => ["INVOKE", "SHUTDOWN"]
                 }
               },
               %{
                 "time" => "2026-10-09T20:00:00.100Z",
                 "type" => "platform.initReport",
                 "record" => %{
                   "initializationType" => "on-demand",
                   "status" => "success",
                   "phase" => "init",
                   "metrics" => %{"durationMs" => 512.3}
                 }
               },
               %{
                 "time" => "2026-10-09T20:00:01.000Z",
                 "type" => "platform.report",
                 "record" => %{
                   "requestId" => "r-1",
                   "status" => "success",
                   "metrics" => %{
                     "durationMs" => 12.5,
                     "billedDurationMs" => 13,
                     "memorySizeMB" => 512,
                     "maxMemoryUsedMB" => 85,
                     "initDurationMs" => 512.3
                   }
                 }
               }
             ])

    assert_receive {:platform, [:mayfly, :platform, :extension], %{},
                    %{record: %{"name" => "mayfly"}}}

    assert_receive {:platform, [:mayfly, :platform, :init_report], %{duration_ms: 512.3},
                    %{status: "success"}}

    assert_receive {:platform, [:mayfly, :platform, :report],
                    %{
                      duration_ms: 12.5,
                      billed_duration_ms: 13,
                      memory_size_mb: 512,
                      max_memory_used_mb: 85,
                      init_duration_ms: 512.3
                    }, %{request_id: "r-1", status: "success", time: "2026-10-09T20:00:01.000Z"}}
  end

  # Lambda never sends SHUTDOWN to internal extensions; the handler exists for
  # completeness and the emulator lets us exercise it.
  test "a SHUTDOWN event (if delivered) flushes and halts" do
    {rt, _sup, _ext} = start()
    test = self()
    ref = make_ref()

    :telemetry.attach(
      {ref, :shutdown},
      [:mayfly, :extension, :shutdown],
      fn _, _, md, _ -> send(test, {:shutdown_event, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({ref, :shutdown}) end)

    # INVOKE events must not confuse the loop: one invocation first.
    assert {:ok, _} = LocalRuntime.invoke(rt, %{"x" => 1})
    :ok = LocalRuntime.shutdown(rt, "spindown")
    assert_receive {:shutdown_event, %{record: %{"shutdownReason" => "spindown"}}}, 2_000
    assert_receive {:halted, 0}, 2_000
  end

  test "disabled by default; enabled?/1 honours option, env and app env" do
    rt = start_supervised!({LocalRuntime, []}, id: make_ref())

    {:ok, sup} =
      Mayfly.start_link(
        handler: "Mayfly.Test.Handlers.Echo",
        runtime_api: LocalRuntime.address(rt),
        name: nil
      )

    refute Enum.any?(Supervisor.which_children(sup), fn {mod, _, _, _} -> mod == Extension end)
    assert LocalRuntime.extensions(rt) == %{}

    refute Extension.enabled?([])
    assert Extension.enabled?(extension: true)
    refute Extension.enabled?(extension: false)
  end

  test "registration failure stops the runtime start" do
    # Point the extension at a closed port while the runtime API itself works.
    rt = start_supervised!({LocalRuntime, []}, id: make_ref())
    Process.flag(:trap_exit, true)

    result =
      Mayfly.start_link(
        handler: "Mayfly.Test.Handlers.Echo",
        runtime_api: LocalRuntime.address(rt),
        name: nil,
        extension: true,
        extension_opts: [name: nil, endpoint: {"127.0.0.1", 1}]
      )

    assert {:error,
            {:shutdown, {:failed_to_start_child, Extension, {:extension, {:register, _}}}}} =
             result
  end
end
