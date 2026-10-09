defmodule Mayfly.Events.Util do
  @moduledoc false
  # Small helpers shared by the event decoders. Not part of the public API.

  @doc "JSON-decodes a binary when it parses, otherwise returns it unchanged. nil stays nil."
  @spec maybe_json(term()) :: term()
  def maybe_json(nil), do: nil

  def maybe_json(bin) when is_binary(bin) do
    case JSON.decode(bin) do
      {:ok, term} -> term
      {:error, _} -> bin
    end
  end

  def maybe_json(other), do: other

  @doc "Base64-decodes when the flag is truthy; tolerates nil."
  @spec maybe_base64(binary() | nil, boolean() | nil) :: binary() | nil
  def maybe_base64(nil, _), do: nil

  def maybe_base64(bin, true) when is_binary(bin) do
    case Base.decode64(bin) do
      {:ok, decoded} -> decoded
      :error -> bin
    end
  end

  def maybe_base64(bin, _), do: bin

  @doc "Lowercases header names; joins list values with a comma (RFC 9110)."
  @spec headers(map() | nil) :: %{optional(String.t()) => String.t()}
  def headers(nil), do: %{}

  def headers(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_list(v) -> {String.downcase(k), Enum.join(v, ", ")}
      {k, v} -> {String.downcase(k), to_string(v)}
    end)
  end

  @doc "S3 keys arrive URL-encoded with `+` for spaces."
  @spec url_decode(String.t() | nil) :: String.t() | nil
  def url_decode(nil), do: nil
  def url_decode(key), do: key |> String.replace("+", " ") |> URI.decode()

  @doc "Parses an ISO 8601 timestamp into DateTime, or returns the input when it does not parse."
  @spec datetime(String.t() | nil) :: DateTime.t() | String.t() | nil
  def datetime(nil), do: nil

  def datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> str
    end
  end

  @doc "Parses a decimal string into integer or float; nil stays nil, unparsable stays as is."
  @spec number(String.t() | number() | nil) :: number() | String.t() | nil
  def number(nil), do: nil
  def number(n) when is_number(n), do: n

  def number(str) when is_binary(str) do
    case Integer.parse(str) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(str) do
          {float, ""} -> float
          _ -> str
        end
    end
  end

  @doc "Lambda-style partial batch response."
  @spec batch_failures([String.t()]) :: %{batchItemFailures: [%{itemIdentifier: String.t()}]}
  def batch_failures(ids) when is_list(ids) do
    %{batchItemFailures: Enum.map(ids, &%{itemIdentifier: &1})}
  end

  @doc """
  Runs `fun` for every record, collecting identifiers of the ones that
  returned `{:error, _}`, raised, exited or threw. `id_fun` extracts the
  identifier from a record.
  """
  @spec process_batch([struct()], (struct() -> term()), (struct() -> String.t())) ::
          %{batchItemFailures: [%{itemIdentifier: String.t()}]}
  def process_batch(records, fun, id_fun) do
    failed =
      for record <- records,
          failed?(fn -> fun.(record) end),
          do: id_fun.(record)

    batch_failures(failed)
  end

  defp failed?(fun) do
    case fun.() do
      {:error, _} -> true
      _ -> false
    end
  rescue
    _ -> true
  catch
    _kind, _reason -> true
  end
end
