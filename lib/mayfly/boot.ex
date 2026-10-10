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

    with :ok <- start_applications(),
         :ok <- start_shutdown() do
      start_runtime()
    else
      {:error, payload} ->
        # Report what we can before exiting; without this Lambda only shows Runtime.ExitError.
        Logger.error("Initialisation failed: #{payload.errorType}: #{payload.errorMessage}")
        report_init_error(payload)
        System.halt(1)
    end
  end

  defp start_runtime do
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
    # Only override the level when Lambda/the user set it; otherwise the
    # application's own config (config :logger, level: ...) stands.
    case System.get_env("LOGLEVEL") || System.get_env("AWS_LAMBDA_LOG_LEVEL") do
      nil -> :ok
      level -> Logger.configure(level: level |> String.downcase() |> to_level())
    end

    if System.get_env("AWS_LAMBDA_LOG_FORMAT") == "JSON" do
      :logger.update_handler_config(:default, :formatter, {Mayfly.LogFormatter, %{}})
    end
  end

  defp start_applications do
    # Every application the release loaded is started (the release's start
    # types are not consulted: a Lambda function has no reason to keep an
    # application loaded but stopped). :mayfly itself has no application callback.
    Enum.reduce_while(Application.loaded_applications(), :ok, fn
      {:mayfly, _, _}, acc ->
        {:cont, acc}

      {app, _desc, _vsn}, acc ->
        case Application.ensure_all_started(app) do
          {:ok, _} ->
            {:cont, acc}

          {:error, reason} ->
            {:halt,
             {:error,
              Mayfly.ErrorPayload.runtime(
                "InitError",
                "could not start application #{app}: #{inspect(reason, limit: 50, printable_limit: 500)}"
              )}}
        end
    end)
  end

  # SIGTERM arrives only when the mayfly-shutdown extension layer is attached.
  defp start_shutdown do
    case Mayfly.Shutdown.start_link() do
      {:ok, _} ->
        :ok

      # The application supervises Mayfly.Shutdown itself: fine, use that one.
      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        {:error,
         Mayfly.ErrorPayload.runtime(
           "InitError",
           "could not install the shutdown handler: #{inspect(reason)}"
         )}
    end
  end

  defp report_init_error(payload) do
    case System.get_env("AWS_LAMBDA_RUNTIME_API") do
      nil ->
        :ok

      api ->
        [host, port] = String.split(api, ":", parts: 2)

        case Mayfly.RuntimeAPI.init_error({host, String.to_integer(port)}, payload) do
          :ok -> :ok
          {:error, reason} -> Logger.error("Could not report init error: #{inspect(reason)}")
        end
    end
  end

  defp to_level(l) when l in ~w(trace debug), do: :debug
  defp to_level("info"), do: :info
  defp to_level(l) when l in ~w(warn warning), do: :warning
  defp to_level(l) when l in ~w(error fatal), do: :error
  defp to_level(_), do: :info
end
