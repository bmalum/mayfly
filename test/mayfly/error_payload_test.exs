defmodule Mayfly.ErrorPayloadTest do
  use ExUnit.Case, async: true

  alias Mayfly.ErrorPayload

  doctest Mayfly.ErrorPayload

  defmodule CustomError, do: defexception(message: "custom")

  describe "from_term/2" do
    test "exceptions use Exception.message/1 and the bare module name" do
      assert %{errorType: "KeyError", errorMessage: msg, stackTrace: []} =
               ErrorPayload.from_term(%KeyError{key: "a", term: %{}})

      assert msg =~ ~s(key "a" not found)

      assert %{errorType: "UndefinedFunctionError", errorMessage: msg} =
               ErrorPayload.from_term(%UndefinedFunctionError{
                 module: Foo,
                 function: :bar,
                 arity: 1
               })

      assert msg =~ "Foo.bar/1"

      assert %{errorType: "Mayfly.ErrorPayloadTest.CustomError", errorMessage: "custom"} =
               ErrorPayload.from_term(%CustomError{})
    end

    test "strings and terms are HandlerError; structured maps pass through" do
      assert %{errorType: "HandlerError", errorMessage: "boom"} = ErrorPayload.from_term("boom")

      assert %{errorType: "HandlerError", errorMessage: "{:some, :tuple}"} =
               ErrorPayload.from_term({:some, :tuple})

      assert %{errorType: "MyApp.NotFound", errorMessage: "gone"} =
               ErrorPayload.from_term(%{errorType: "MyApp.NotFound", errorMessage: "gone"})

      assert %{errorType: "MyApp.NotFound"} =
               ErrorPayload.from_term(%{
                 "errorType" => "MyApp.NotFound",
                 "errorMessage" => "gone"
               })
    end

    test "inspect output is bounded" do
      %{errorMessage: msg} = ErrorPayload.from_term(Enum.to_list(1..10_000))
      assert String.length(msg) < 400
    end

    test "stack traces are lists with Mayfly frames removed" do
      st = [
        {MyApp.Handler, :handle, 3, [file: ~c"lib/h.ex", line: 10]},
        {Mayfly.Handler, :invoke, 3, [file: ~c"lib/mayfly/handler.ex", line: 90]},
        {Mayfly.Poller, :process, 3, []}
      ]

      assert %{stackTrace: ["lib/h.ex:10: MyApp.Handler.handle/3"]} =
               ErrorPayload.from_term(%RuntimeError{message: "x"}, st)
    end
  end

  test "from_caught/3" do
    assert %{errorType: "Exit", errorMessage: msg} =
             ErrorPayload.from_caught(:exit, :shutdown, nil)

    assert msg =~ "shutdown"

    assert %{errorType: "Throw", errorMessage: "Uncaught throw: :ball"} =
             ErrorPayload.from_caught(:throw, :ball, [])

    assert %{errorType: "ArithmeticError"} = ErrorPayload.from_caught(:error, :badarith, [])
  end

  test "runtime/2" do
    assert %{errorType: "Runtime.NoSuchHandler", errorMessage: "x", stackTrace: []} =
             ErrorPayload.runtime("NoSuchHandler", "x")
  end

  test "header_type/1 always yields Category.Reason" do
    assert ErrorPayload.header_type("Runtime.InvalidResponse") == "Runtime.InvalidResponse"
    assert ErrorPayload.header_type("Function.Custom") == "Function.Custom"
    assert ErrorPayload.header_type("KeyError") == "Function.KeyError"
    assert ErrorPayload.header_type("MyApp.Not-Found") == "Function.MyAppNotFound"
    assert ErrorPayload.header_type("lowercase") == "Function.Lowercase"
    assert ErrorPayload.header_type("42") == "Function.E42"
    assert ErrorPayload.header_type("") == "Function.Unknown"
  end

  test "xray_cause/1 is JSON encodable" do
    payload = ErrorPayload.from_term(%RuntimeError{message: "x"}, [{MyApp, :f, 1, []}])

    assert %{"exceptions" => [%{"type" => "RuntimeError", "stack" => [_]}]} =
             payload |> ErrorPayload.xray_cause() |> JSON.encode!() |> JSON.decode!()
  end
end
