defmodule Mayfly.ErrorPayload do
  @moduledoc """
  Builds the error document Lambda expects on `/runtime/invocation/<id>/error`
  and `/runtime/init/error`:

      %{errorType: "KeyError", errorMessage: "key :a not found", stackTrace: [...]}

  ## Error types

    * Exceptions raised by a handler use their module name
      (`"KeyError"`, `"MyApp.ValidationError"`).
    * `{:error, reason}` returned by a handler is `"HandlerError"`, unless
      `reason` is already a map with `errorType`/`errorMessage` (atom or string
      keys), which is passed through so handlers can emit structured errors.
    * `exit/1` and `throw/1` become `"Exit"` and `"Throw"`.
    * Runtime-detected problems use `Runtime.*` types
      (`Runtime.InvalidResponse`, `Runtime.NoSuchHandler`, ...).

  ## Header type

  Lambda classifies errors by the `Lambda-Runtime-Function-Error-Type` header
  and normalises anything not shaped like `<Category.Reason>` (Category being
  `Runtime` or `Function`) to `Runtime.Unknown`/`Function.Unknown`.
  `header_type/1` derives a conforming value: `Runtime.*` is kept as is, every
  other type is prefixed with `Function.` and stripped of dots.

  Whatever a handler returns in `{:error, reason}` ends up in the payload,
  which API Gateway may forward to clients. Terms are rendered with a bounded
  `inspect/2`.
  """

  @type t :: %{errorType: String.t(), errorMessage: String.t(), stackTrace: [String.t()]}

  @inspect_opts [limit: 50, printable_limit: 500]
  @doc "Builds a payload from an exception, a handler `{:error, reason}` value or any term."
  @spec from_term(term(), Exception.stacktrace() | nil) :: t()
  def from_term(term, stacktrace \\ nil)

  def from_term(%{__exception__: true} = exception, stacktrace) do
    new(inspect(exception.__struct__), Exception.message(exception), stacktrace)
  end

  def from_term(%{errorType: type, errorMessage: message}, stacktrace)
      when is_binary(type) and is_binary(message),
      do: new(type, message, stacktrace)

  def from_term(%{"errorType" => type, "errorMessage" => message}, stacktrace)
      when is_binary(type) and is_binary(message),
      do: new(type, message, stacktrace)

  def from_term(%{__struct__: struct} = value, stacktrace),
    do: new(inspect(struct), safe_inspect(value), stacktrace)

  def from_term(message, stacktrace) when is_binary(message),
    do: new("HandlerError", message, stacktrace)

  def from_term(term, stacktrace), do: new("HandlerError", safe_inspect(term), stacktrace)

  @doc "Builds a payload from a value caught with `catch kind, reason`."
  @spec from_caught(:exit | :throw | :error, term(), Exception.stacktrace() | nil) :: t()
  def from_caught(:error, reason, stacktrace),
    do: from_term(Exception.normalize(:error, reason, stacktrace), stacktrace)

  def from_caught(:exit, reason, stacktrace),
    do: new("Exit", Exception.format_exit(reason), stacktrace)

  def from_caught(:throw, value, stacktrace),
    do: new("Throw", "Uncaught throw: " <> safe_inspect(value), stacktrace)

  @doc "Builds a runtime error payload with an explicit `Runtime.*` type."
  @spec runtime(String.t(), String.t()) :: t()
  def runtime(reason, message) when is_binary(reason) and is_binary(message),
    do: new("Runtime." <> reason, message, nil)

  @doc """
  Value for the `Lambda-Runtime-Function-Error-Type` header.

      iex> Mayfly.ErrorPayload.header_type("Runtime.InvalidResponse")
      "Runtime.InvalidResponse"
      iex> Mayfly.ErrorPayload.header_type("MyApp.Validation.Error")
      "Function.MyAppValidationError"
      iex> Mayfly.ErrorPayload.header_type("HandlerError")
      "Function.HandlerError"
  """
  @spec header_type(String.t()) :: String.t()
  def header_type("Runtime." <> reason), do: "Runtime." <> clean_reason(reason)
  def header_type("Function." <> reason), do: "Function." <> clean_reason(reason)
  def header_type(type) when is_binary(type), do: "Function." <> clean_reason(type)

  # Header values must be a single token: strip anything that is not alphanumeric.
  defp clean_reason(reason),
    do: reason |> String.replace(~r/[^A-Za-z0-9]/, "") |> ensure_uppercase()

  @doc """
  Formats a stacktrace as a list of lines, dropping frames that belong to
  Mayfly itself so the handler's frames come first.
  """
  @spec format_stacktrace(Exception.stacktrace() | nil) :: [String.t()]
  def format_stacktrace(nil), do: []

  def format_stacktrace(stacktrace) when is_list(stacktrace) do
    # Cut where Mayfly called into the handler (Mayfly.Handler / Mayfly.Poller);
    # frames of other Mayfly modules above that point (Events, Response helpers
    # the handler used) stay, they are part of the user's call path.
    stacktrace
    |> Enum.take_while(&(not invocation_boundary?(&1)))
    |> Enum.map(&Exception.format_stacktrace_entry/1)
  end

  @doc "X-Ray cause document (`Lambda-Runtime-Function-Xray-Error-Cause`)."
  @spec xray_cause(t()) :: map()
  def xray_cause(%{errorType: type, errorMessage: message, stackTrace: trace}) do
    %{
      working_directory: File.cwd!(),
      paths: [],
      exceptions: [
        %{
          type: type,
          message: message,
          stack: Enum.map(trace, &%{path: "", line: 0, label: &1})
        }
      ]
    }
  end

  # errorType and errorMessage end up in JSON: non-UTF-8 binaries would make the
  # error report itself fail, so they are inspected instead.
  defp new(type, message, stacktrace) do
    %{
      errorType: utf8(type, "HandlerError"),
      errorMessage: utf8(message, nil),
      stackTrace: format_stacktrace(stacktrace)
    }
  end

  defp utf8(bin, _fallback) when is_binary(bin) and byte_size(bin) <= 65_536 do
    if String.valid?(bin), do: bin, else: safe_inspect(bin)
  end

  defp utf8(bin, nil) when is_binary(bin),
    do: binary_part(bin, 0, 65_536) |> utf8(nil) |> Kernel.<>("… (truncated)")

  defp utf8(_bin, fallback) when is_binary(fallback), do: fallback
  defp utf8(other, _), do: safe_inspect(other)

  defp invocation_boundary?({module, _f, _a, _loc}), do: module in [Mayfly.Handler, Mayfly.Poller]
  defp invocation_boundary?(_), do: false

  defp safe_inspect(term), do: inspect(term, @inspect_opts)

  defp ensure_uppercase(""), do: "Unknown"
  defp ensure_uppercase(<<c, rest::binary>>) when c in ?a..?z, do: <<c - 32, rest::binary>>
  defp ensure_uppercase(<<c, _::binary>> = s) when c in ?A..?Z, do: s
  defp ensure_uppercase(s), do: "E" <> s
end
