defmodule Mayfly.Boot do
  @moduledoc """
  Entry point used by the generated `bootstrap` script:

      bin/my_app eval "Mayfly.Boot.main()"

  `main/0` configures logging from Lambda's environment
  (`AWS_LAMBDA_LOG_FORMAT`, `AWS_LAMBDA_LOG_LEVEL`, `LOGLEVEL`), starts the
  user's OTP application(s) and then the runtime, and blocks forever. If the
  runtime cannot initialise (bad handler, failing `init/1`) the error has been
  reported to Lambda and the VM exits with status 1.

  Nothing in Mayfly starts implicitly: adding the dependency has no effect on
  `mix test` or `iex -S mix` in your project.
  """

  require Logger

  @spec main([String.t()]) :: no_return()
  def main(_args \\ []) do
    configure_logger()
    start_applications()
    # SIGTERM arrives only when the mayfly-shutdown extension layer is attached.
    {:ok, _} = Mayfly.Shutdown.start_link()

    case Mayfly.start_link() do
      {:ok, _pid} ->
        Process.sleep(:infinity)

      {:error, {:init_error, _payload}} ->
        # Already reported to /runtime/init/error and logged.
        System.halt(1)

      {:error, reason} ->
        Logger.error("Mayfly failed to start: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc false
  def configure_logger do
    level =
      (System.get_env("LOGLEVEL") || System.get_env("AWS_LAMBDA_LOG_LEVEL") || "info")
      |> String.downcase()
      |> to_level()

    Logger.configure(level: level)

    if System.get_env("AWS_LAMBDA_LOG_FORMAT") == "JSON" do
      :logger.update_handler_config(:default, :formatter, {Mayfly.LogFormatter, %{}})
    end
  end

  defp start_applications do
    # The release's applications list is in :included/:applications order; the
    # user's app is the one that depends on :mayfly. Starting :mayfly's own
    # dependents is enough to bring up everything the release contains.
    for {app, _desc, _vsn} <- Application.loaded_applications(), app != :mayfly do
      case Application.ensure_all_started(app) do
        {:ok, _} -> :ok
        {:error, reason} -> raise "could not start #{app}: #{inspect(reason)}"
      end
    end
  end

  defp to_level(l) when l in ~w(trace debug), do: :debug
  defp to_level("info"), do: :info
  defp to_level(l) when l in ~w(warn warning), do: :warning
  defp to_level(l) when l in ~w(error fatal), do: :error
  defp to_level(_), do: :info
end
