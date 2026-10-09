defmodule Mix.Tasks.Lambda.Catalog do
  @moduledoc false
  # Dev-time access to the public layer catalog at elixir-aws-lambda.dev, shared
  # by `mix lambda.doctor` and `mix lambda.new`. Not part of the runtime.

  @catalog "https://elixir-aws-lambda.dev/layers"

  @doc "Base URL of the catalog."
  def url, do: @catalog

  @doc """
  Newest published layer for an OTP major (or exact version), arch and region:
  `{:ok, %{"otp" => "27.3.4.18", "arn" => ..., ...}}`, `{:error, :not_found}`
  or `{:error, reason}` when the catalog is unreachable.
  """
  def layer(otp, arch, region), do: fetch_json("#{@catalog}/#{otp}/#{arch}/#{region}.json")

  @doc "Fallback table used when the catalog is unreachable: newest patch per major at release time."
  def offline_otp(major) do
    Map.get(%{"27" => "27.3.4.18", "28" => "28.5.0.7", "29" => "29.1.1"}, to_string(major))
  end

  @doc "Elixir version to pair with an OTP major (precompiled builds exist for these)."
  def elixir_for(major) do
    Map.get(%{"27" => "1.18.4", "28" => "1.19.3", "29" => "1.20.2"}, to_string(major), "1.18.4")
  end

  @doc "Region from the environment, defaulting to eu-central-1."
  def default_region do
    System.get_env("AWS_REGION") || System.get_env("AWS_DEFAULT_REGION") || "eu-central-1"
  end

  # :inets/:ssl are not Mayfly dependencies (the runtime uses :gen_tcp), so the
  # calls go through apply/3 to keep the compiler quiet; this is a dev-time task.
  @doc false
  def fetch_json(url) do
    # Mix prunes code paths to the project's applications; put the OTP apps
    # this task needs back on the path before loading them.
    for app <- [:asn1, :public_key, :ssl, :inets] do
      Code.prepend_path(:filename.join(:code.lib_dir(), ~c"#{app}-#{otp_app_vsn(app)}/ebin"))
      Application.load(app)
      {:ok, _} = Application.ensure_all_started(app)
    end

    request = {String.to_charlist(url), [{~c"user-agent", ~c"mix lambda"}]}
    cacerts = apply(:public_key, :cacerts_get, [])

    http_opts = [
      timeout: 5_000,
      connect_timeout: 3_000,
      ssl: [verify: :verify_peer, cacerts: cacerts]
    ]

    case apply(:httpc, :request, [:get, request, http_opts, [body_format: :binary]]) do
      {:ok, {{_, 200, _}, _, body}} -> JSON.decode(body)
      {:ok, {{_, 404, _}, _, _}} -> {:error, :not_found}
      {:ok, {{_, status, _}, _, _}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp otp_app_vsn(app) do
    :code.lib_dir()
    |> File.ls!()
    |> Enum.find(&String.starts_with?(&1, "#{app}-"))
    |> String.replace_prefix("#{app}-", "")
  end
end
