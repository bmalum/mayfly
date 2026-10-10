defmodule Mayfly.ShutdownTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Mayfly.Shutdown

  test "run/1 executes hooks in registration order, flushes and halts" do
    test = self()

    {:ok, pid} =
      Shutdown.start_link(
        name: nil,
        signals: false,
        halt: fn code -> send(test, {:halted, code}) end
      )

    :ok = Shutdown.register(fn -> send(test, :hook1) end, pid)
    :ok = Shutdown.register(fn -> send(test, :hook2) end, pid)

    :telemetry.attach(
      make_ref(),
      [:mayfly, :shutdown],
      fn _, _, md, _ -> send(test, {:shutdown_event, md}) end,
      nil
    )

    :ok = Shutdown.run(pid)
    assert_receive :hook1
    assert_receive :hook2
    assert_receive {:shutdown_event, %{reason: :manual}}
    assert_receive {:halted, 0}
  end

  test "a slow or crashing hook does not prevent the halt" do
    test = self()

    {:ok, pid} =
      Shutdown.start_link(
        name: nil,
        signals: false,
        hook_timeout_ms: 50,
        halt: fn code -> send(test, {:halted, code}) end
      )

    :ok = Shutdown.register(fn -> Process.sleep(5_000) end, pid)
    :ok = Shutdown.register(fn -> raise "boom" end, pid)
    :ok = Shutdown.register(fn -> send(test, :last) end, pid)
    :ok = Shutdown.run(pid)
    assert_receive :last
    assert_receive {:halted, 0}
  end

  @tag :tmp_dir
  test "a real SIGTERM reaches the handler in a child VM", %{tmp_dir: tmp} do
    marker = Path.join(tmp, "flushed")

    script = """
    {:ok, _} = Mayfly.Shutdown.start_link()
    Mayfly.Shutdown.register(fn -> File.write!(#{inspect(marker)}, "hook ran") end)
    IO.puts("READY")
    Process.sleep(:infinity)
    """

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        args: ["-pa", Path.join(Mix.Project.app_path(), "ebin"), "-e", script]
      ])

    assert_receive {^port, {:data, "READY\n"}}, 15_000
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
    assert_receive {^port, {:exit_status, 0}}, 10_000
    assert File.read!(marker) == "hook ran"
  end

  test "a global deadline bounds all hooks together and register/1 without a server is a no-op" do
    test = self()

    {:ok, pid} =
      Shutdown.start_link(
        name: nil,
        signals: false,
        hook_timeout_ms: 500,
        deadline_ms: 300,
        halt: fn code -> send(test, {:halted, code}) end
      )

    for _ <- 1..3, do: :ok = Shutdown.register(fn -> Process.sleep(1_000) end, pid)
    :ok = Shutdown.register(fn -> send(test, :never) end, pid)
    started = System.monotonic_time(:millisecond)
    :ok = Shutdown.run(pid)
    assert_receive {:halted, 0}, 2_000
    assert System.monotonic_time(:millisecond) - started < 1_000
    refute_received :never

    assert :ok = Shutdown.register(fn -> :ok end, :no_such_shutdown_server)
  end
end
