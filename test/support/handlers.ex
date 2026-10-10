defmodule Mayfly.Test.Handlers do
  @moduledoc false

  defmodule Echo do
    @moduledoc false
    use Mayfly.Handler

    @impl true
    def handle(event, _ctx, _state), do: {:ok, event}
  end

  defmodule WithInit do
    @moduledoc false
    use Mayfly.Handler

    @impl true
    def init(opts), do: {:ok, %{opts: opts, started_at: System.monotonic_time()}}

    @impl true
    def handle(event, %Mayfly.Context{} = ctx, state) do
      {:ok,
       %{
         event: event,
         request_id: ctx.request_id,
         tenant_id: ctx.tenant_id,
         opts: Map.new(state.opts)
       }}
    end
  end

  defmodule InitFails do
    @moduledoc false
    use Mayfly.Handler

    @impl true
    def init(_opts), do: {:error, "no database"}

    @impl true
    def handle(_event, _ctx, _state), do: {:ok, nil}
  end

  defmodule InitRaises do
    @moduledoc false
    use Mayfly.Handler

    @impl true
    def init(_opts), do: raise("init exploded")

    @impl true
    def handle(_event, _ctx, _state), do: {:ok, nil}
  end

  defmodule Faulty do
    @moduledoc false
    use Mayfly.Handler

    @impl true
    def handle(%{"mode" => "raise"}, _ctx, _s), do: raise(ArgumentError, "bad argument")
    def handle(%{"mode" => "key"} = e, _ctx, _s), do: {:ok, Map.fetch!(e, "missing")}
    def handle(%{"mode" => "exit"}, _ctx, _s), do: exit(:shutdown)
    def handle(%{"mode" => "throw"}, _ctx, _s), do: throw(:ball)
    def handle(%{"mode" => "error_string"}, _ctx, _s), do: {:error, "boom"}

    def handle(%{"mode" => "error_map"}, _ctx, _s),
      do: {:error, %{errorType: "MyApp.NotFound", errorMessage: "no such thing"}}

    # A linked process dying takes the invocation process down from the outside.
    def handle(%{"mode" => "linked_crash"}, _ctx, _s) do
      Task.async(fn -> raise "task died" end) |> Task.await()
    end

    def handle(%{"mode" => "kill_self"}, _ctx, _s), do: Process.exit(self(), :kill)
    def handle(%{"mode" => "binary_error"}, _ctx, _s), do: {:error, <<255, 254, 0>>}

    def handle(%{"mode" => "bad_iodata"}, _ctx, _s),
      do: {:ok, %Mayfly.Response{body: [1000, %{}], content_type: "text/plain"}}

    def handle(%{"mode" => "prefixed_type"}, _ctx, _s),
      do: {:error, %{errorType: "Runtime.Evil\r\nX: y", errorMessage: "x"}}

    def handle(%{"mode" => "bare"}, _ctx, _s), do: %{status: "ok"}
    def handle(%{"mode" => "unencodable"}, _ctx, _s), do: {:ok, {:a, :tuple}}

    def handle(%{"mode" => "slow"}, _ctx, _s) do
      Process.sleep(200)
      {:ok, "done"}
    end

    def handle(event, _ctx, _s), do: {:ok, event}
  end

  defmodule Streaming do
    @moduledoc false
    use Mayfly.Handler

    @impl true
    def handle(%{"mode" => "midstream_error"}, _ctx, _s) do
      stream =
        Stream.map([1, 2, :boom], fn
          :boom -> raise "stream broke"
          n -> "chunk#{n}\n"
        end)

      {:ok,
       %Mayfly.Response{body: stream, content_type: "text/plain"} |> Mayfly.Response.stream()}
    end

    def handle(%{"mode" => "http"}, _ctx, _s) do
      {:ok,
       %Mayfly.Response{body: ["a", "b", "c"]}
       |> Mayfly.Response.stream()
       |> Mayfly.Response.http(status: 201, headers: %{"x-test" => "1"}, cookies: ["a=b"])}
    end

    def handle(_event, _ctx, _s) do
      chunks = Stream.map(1..3, &"chunk#{&1}\n")

      {:ok,
       %Mayfly.Response{body: chunks, content_type: "text/plain"} |> Mayfly.Response.stream()}
    end
  end

  defmodule Binary do
    @moduledoc false
    use Mayfly.Handler

    @impl true
    def handle(_event, _ctx, _s),
      do: {:ok, %Mayfly.Response{body: <<1, 2, 3>>, content_type: "application/octet-stream"}}
  end

  defmodule NotAHandler do
    @moduledoc false
    def something, do: :ok
  end

  # Legacy Module.function style
  def legacy1(event), do: {:ok, %{legacy: 1, event: event}}

  def legacy2(event, %Mayfly.Context{} = ctx),
    do: {:ok, %{legacy: 2, event: event, request_id: ctx.request_id}}
end
