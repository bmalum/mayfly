defmodule Mayfly.MetricsTest do
  use ExUnit.Case, async: true

  alias Mayfly.Metrics

  defp capture(fun) do
    {:ok, dev} = StringIO.open("")
    fun.(dev)
    {_, out} = StringIO.contents(dev)
    out
  end

  test "build/3 produces the EMF shape" do
    record =
      Metrics.build("MyApp", %{"Orders" => 1, "Cart" => {12.5, "None"}},
        dimensions: %{"Tenant" => "blue"},
        properties: %{"orderId" => "o1"},
        timestamp: 1_700_000_000_000
      )

    assert record["_aws"] == %{
             "Timestamp" => 1_700_000_000_000,
             "CloudWatchMetrics" => [
               %{
                 "Namespace" => "MyApp",
                 "Dimensions" => [["Tenant"]],
                 "Metrics" => [
                   %{"Name" => "Cart", "Unit" => "None", "StorageResolution" => 60},
                   %{"Name" => "Orders", "Unit" => "Count", "StorageResolution" => 60}
                 ]
               }
             ]
           }

    assert record["Tenant"] == "blue"
    assert record["Orders"] == 1
    assert record["Cart"] == 12.5
    assert record["orderId"] == "o1"
  end

  test "emit writes exactly one standalone JSON line" do
    out = capture(fn dev -> Metrics.emit("NS", %{"A" => 1}, device: dev) end)
    assert [line] = String.split(out, "\n", trim: true)
    assert %{"_aws" => _, "A" => 1} = JSON.decode!(line)
    assert String.ends_with?(out, "\n")
  end

  test "count/4 and timing/4 set units; high_resolution sets StorageResolution 1" do
    out = capture(fn dev -> Metrics.count("NS", "Hits", 3, device: dev) end)

    assert %{
             "_aws" => %{
               "CloudWatchMetrics" => [%{"Metrics" => [%{"Name" => "Hits", "Unit" => "Count"}]}]
             },
             "Hits" => 3
           } = JSON.decode!(out)

    out =
      capture(fn dev -> Metrics.timing("NS", "Lat", 42, high_resolution: true, device: dev) end)

    assert %{
             "_aws" => %{
               "CloudWatchMetrics" => [
                 %{"Metrics" => [%{"Unit" => "Milliseconds", "StorageResolution" => 1}]}
               ]
             }
           } = JSON.decode!(out)
  end

  test "validation" do
    assert_raise ArgumentError, ~r/unknown EMF unit/, fn ->
      Metrics.build("NS", %{"A" => {1, "Furlongs"}})
    end

    assert_raise ArgumentError, ~r/at most 30 dimensions/, fn ->
      Metrics.build("NS", %{"A" => 1}, dimensions: Map.new(1..31, &{"d#{&1}", "x"}))
    end

    assert_raise ArgumentError, ~r/1\.\.100 metrics/, fn -> Metrics.build("NS", %{}) end

    assert_raise ArgumentError, ~r/must be a number/, fn ->
      Metrics.build("NS", %{"A" => "one"})
    end
  end

  test "attach_invocation_metrics emits Duration/Errors/ColdStart, ColdStart only once" do
    {:ok, dev} = StringIO.open("")
    ns = "T#{System.unique_integer([:positive])}"
    assert :ok = Metrics.attach_invocation_metrics(ns, device: dev)
    assert {:error, :already_exists} = Metrics.attach_invocation_metrics(ns, device: dev)
    on_exit(fn -> :telemetry.detach({Metrics, ns}) end)

    ctx = %Mayfly.Context{request_id: "r1", env: %{function_name: "fn-a"}}

    :telemetry.execute(
      [:mayfly, :invocation, :stop],
      %{duration: System.convert_time_unit(12, :millisecond, :native)},
      %{context: ctx, result: :ok, error_type: nil}
    )

    :telemetry.execute(
      [:mayfly, :invocation, :stop],
      %{duration: System.convert_time_unit(5, :millisecond, :native)},
      %{context: ctx, result: :error, error_type: "KeyError"}
    )

    {_, out} = StringIO.contents(dev)
    [first, second] = out |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert first["ColdStart"] == 1 and second["ColdStart"] == 0
    assert first["Errors"] == 0 and second["Errors"] == 1
    assert_in_delta first["Duration"], 12.0, 0.5
    assert first["FunctionName"] == "fn-a" and first["requestId"] == "r1"
    assert hd(first["_aws"]["CloudWatchMetrics"])["Namespace"] == ns
    assert hd(first["_aws"]["CloudWatchMetrics"])["Dimensions"] == [["FunctionName"]]
  end
end
