defmodule Mayfly.Error do
  @moduledoc """
  Error handling utilities for AWS Lambda functions.
  Provides standardized error formatting and conversion functions.
  """

  @doc """
  Converts various error types to a standardized Lambda error format.
  """
  @spec format_error(any(), list() | nil) :: map()
  def format_error(error, stacktrace \\ nil)

  def format_error(%{__struct__: struct_type, message: message}, stacktrace) do
    %{
      errorType: to_string(struct_type),
      errorMessage: message,
      stackTrace: format_stacktrace(stacktrace)
    }
  end

  def format_error(%{__struct__: struct_type} = error, stacktrace) do
    %{
      errorType: to_string(struct_type),
      errorMessage: inspect(error),
      stackTrace: format_stacktrace(stacktrace)
    }
  end

  def format_error(error, stacktrace) when is_binary(error) do
    %{
      errorType: "RuntimeError",
      errorMessage: error,
      stackTrace: format_stacktrace(stacktrace)
    }
  end

  def format_error(error, stacktrace) do
    %{
      errorType: "UnknownError",
      errorMessage: inspect(error),
      stackTrace: format_stacktrace(stacktrace)
    }
  end

  @doc """
  Formats stacktrace into a string representation.
  Returns empty string if stacktrace is nil.
  """
  @spec format_stacktrace(list() | nil) :: String.t()
  def format_stacktrace(nil), do: ""
  def format_stacktrace(stacktrace), do: Exception.format_stacktrace(stacktrace)
end
