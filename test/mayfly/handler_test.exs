defmodule Mayfly.HandlerTest do
  use ExUnit.Case, async: true

  alias Mayfly.{Context, Handler, Response}
  alias Mayfly.Test.Handlers

  @ctx %Context{request_id: "req-1", tenant_id: "blue"}

  describe "resolve/2 with behaviour modules" do
    test "module with and without Elixir. prefix" do
      assert {:ok, %{module: Handlers.Echo, state: nil}} =
               Handler.resolve("Mayfly.Test.Handlers.Echo")

      assert {:ok, %{module: Handlers.Echo}} = Handler.resolve("Elixir.Mayfly.Test.Handlers.Echo")
    end

    test "runs init/1 with handler_opts and keeps its state" do
      assert {:ok, %{state: %{opts: [a: 1]}}} =
               Handler.resolve("Mayfly.Test.Handlers.WithInit", a: 1)
    end

    test "init returning {:error, _} is Runtime.InitError" do
      assert {:error, %{errorType: "Runtime.InitError", errorMessage: msg}} =
               Handler.resolve("Mayfly.Test.Handlers.InitFails")

      assert msg =~ "no database"
    end

    test "init raising is Runtime.InitError with the exception message" do
      assert {:error, %{errorType: "Runtime.InitError", errorMessage: msg, stackTrace: [_ | _]}} =
               Handler.resolve("Mayfly.Test.Handlers.InitRaises")

      assert msg =~ "init exploded"
    end

    test "module that does not implement the behaviour" do
      assert {:error, %{errorType: "Runtime.NoSuchHandler", errorMessage: msg}} =
               Handler.resolve("Mayfly.Test.Handlers.NotAHandler")

      assert msg =~ "does not implement Mayfly.Handler"
    end

    test "unknown module and nil" do
      assert {:error,
              %{
                errorType: "Runtime.NoSuchHandler",
                errorMessage: msg
              }} = Handler.resolve("Nope.Missing")

      assert msg =~ "neither module Nope.Missing nor module Nope could be loaded"

      assert {:error, %{errorType: "Runtime.NoSuchHandler", errorMessage: msg}} =
               Handler.resolve(nil)

      assert msg =~ "_HANDLER"
    end
  end

  describe "resolve/2 with legacy Module.function" do
    test "arity 1 and 2 (arity 2 preferred)" do
      assert {:ok, h1} = Handler.resolve("Mayfly.Test.Handlers.legacy1")
      assert {:ok, %Response{body: %{legacy: 1}}} = Handler.invoke(h1, %{}, @ctx)

      assert {:ok, h2} = Handler.resolve("Elixir.Mayfly.Test.Handlers.legacy2")

      assert {:ok, %Response{body: %{legacy: 2, request_id: "req-1"}}} =
               Handler.invoke(h2, %{}, @ctx)
    end

    test "unknown function" do
      assert {:error, %{errorType: "Runtime.NoSuchHandler", errorMessage: msg}} =
               Handler.resolve("Mayfly.Test.Handlers.nope_xyz")

      assert msg =~ "does not export nope_xyz/1 or nope_xyz/2"
    end
  end

  describe "invoke/3" do
    setup do
      {:ok, faulty} = Handler.resolve("Mayfly.Test.Handlers.Faulty")
      %{faulty: faulty}
    end

    test "success is normalised to a Response", %{faulty: h} do
      assert {:ok, %Response{body: %{"x" => 1}, mode: :buffered}} =
               Handler.invoke(h, %{"x" => 1}, @ctx)
    end

    test "context and state reach the handler" do
      {:ok, h} = Handler.resolve("Mayfly.Test.Handlers.WithInit", k: :v)

      assert {:ok, %Response{body: %{request_id: "req-1", tenant_id: "blue", opts: %{k: :v}}}} =
               Handler.invoke(h, %{}, @ctx)
    end

    test "error contract", %{faulty: h} do
      assert {:error, %{errorType: "HandlerError", errorMessage: "boom"}} =
               Handler.invoke(h, %{"mode" => "error_string"}, @ctx)

      assert {:error, %{errorType: "MyApp.NotFound"}} =
               Handler.invoke(h, %{"mode" => "error_map"}, @ctx)

      assert {:error, %{errorType: "Runtime.InvalidResponse", errorMessage: msg}} =
               Handler.invoke(h, %{"mode" => "bare"}, @ctx)

      assert msg =~ ~s(%{status: "ok"})
    end

    test "exceptions, exits and throws are caught", %{faulty: h} do
      assert {:error,
              %{errorType: "ArgumentError", errorMessage: "bad argument", stackTrace: trace}} =
               Handler.invoke(h, %{"mode" => "raise"}, @ctx)

      assert Enum.any?(trace, &(&1 =~ "Handlers.Faulty.handle/3"))
      refute Enum.any?(trace, &(&1 =~ "Mayfly.Handler."))

      assert {:error, %{errorType: "KeyError", errorMessage: msg}} =
               Handler.invoke(h, %{"mode" => "key"}, @ctx)

      assert msg =~ ~s(key "missing" not found)
      assert {:error, %{errorType: "Exit"}} = Handler.invoke(h, %{"mode" => "exit"}, @ctx)
      assert {:error, %{errorType: "Throw"}} = Handler.invoke(h, %{"mode" => "throw"}, @ctx)
    end
  end

  test "legacy Module.function handlers do not get init/1 called" do
    assert {:ok, %{state: nil}} = Mayfly.Handler.resolve("Mayfly.Test.Handlers.legacy1")
  end
end
