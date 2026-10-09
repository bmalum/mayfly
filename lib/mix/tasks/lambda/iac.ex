defmodule Mix.Tasks.Lambda.IaC do
  @moduledoc false
  # Reads the infrastructure files `mix lambda.new` generates (or hand-written
  # ones that follow the same shapes) and reports what Lambda configuration
  # they describe, so `mix lambda.doctor` can compare it with the toolchain.

  @type finding :: %{
          file: String.t(),
          kind: :sam | :terraform | :cdk,
          arch: String.t() | nil,
          otp_major: String.t() | nil,
          layer_arns: [String.t()],
          runtime: String.t() | nil,
          handler: String.t() | nil
        }

  @candidates ~w(template.yaml template.yml infra/template.yaml infra/main.tf infra/variables.tf infra/locals.tf main.tf variables.tf locals.tf infra/bin/app.ts infra/lib/mayfly-function.ts bin/app.ts lib/mayfly-function.ts)

  @doc "IaC files present in `dir`, grouped by tool: `[{:sam, [paths]}, ...]`."
  @spec discover(String.t()) :: [{:sam | :terraform | :cdk, [String.t()]}]
  def discover(dir \\ ".") do
    for rel <- @candidates, path = Path.join(dir, rel), File.regular?(path) do
      kind =
        case Path.extname(rel) do
          ".tf" -> :terraform
          ".ts" -> :cdk
          _ -> :sam
        end

      {kind, path}
    end
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
  end

  @doc "Extracts architecture, OTP major, layer ARNs, runtime and handler from one tool's files (merged)."
  @spec inspect_files(:sam | :terraform | :cdk, [String.t()]) :: finding()
  def inspect_files(kind, paths) do
    content = paths |> Enum.map(&File.read!/1) |> Enum.join("\n")

    %{
      file: paths |> Enum.map(&Path.basename/1) |> Enum.join("+"),
      kind: kind,
      arch: first(content, arch_patterns(kind)),
      otp_major: first(content, otp_patterns(kind)),
      layer_arns:
        Regex.scan(~r/arn:aws:lambda:[a-z0-9-]+:\d{12}:layer:[A-Za-z0-9_-]+:\d+/, content)
        |> List.flatten()
        |> Enum.uniq(),
      runtime: first(content, [~r/Runtime:\s*"?([a-z0-9.]+)/, ~r/runtime\s*=\s*"([a-z0-9.]+)"/]),
      handler: first(content, handler_patterns(kind))
    }
  end

  @doc """
  Compares a finding with the toolchain. Returns a list of doctor results
  (`{:ok | :warn | :error, label, hint}`).
  """
  @spec check(finding(), String.t(), String.t() | nil) :: [
          {:ok | :warn | :error, String.t(), String.t() | nil}
        ]
  def check(%{file: file} = f, local_otp, expected_arch) do
    local_major = local_otp |> String.split(".") |> hd()

    otp_result =
      case f.otp_major do
        nil ->
          []

        ^local_major ->
          [{:ok, "#{file}: OTP major #{f.otp_major} matches the toolchain (#{local_otp})", nil}]

        other ->
          [
            {:error, "#{file}: OTP major #{other} but the toolchain is OTP #{local_otp}",
             "bootstrap requires the layer's exact OTP; change the IaC parameter/variable or `mise use erlang@<#{other}.x>`"}
          ]
      end

    # Pinned ARNs name the OTP in the layer name: mayfly-erlang-27-3-4-18-arm64.
    arn_results =
      for arn <- relevant_layers(f),
          [_, otp_dashed, arch] <- [
            Regex.run(~r/mayfly-erlang-([\d-]+)-(arm64|x86_64):\d+$/, arn)
          ] do
        otp = String.replace(otp_dashed, "-", ".")

        cond do
          otp == local_otp ->
            {:ok,
             "#{file}: layer #{short(arn)} matches OTP #{local_otp}#{arch_note(arch, expected_arch)}",
             nil}

          not String.contains?(otp, ".") and otp == local_major ->
            {:ok, "#{file}: layer alias #{short(arn)} (OTP #{otp}.x) for toolchain #{local_otp}",
             nil}

          true ->
            {:error,
             "#{file}: layer #{short(arn)} is OTP #{otp} but the toolchain is #{local_otp}",
             "build with `mise use erlang@#{otp}` or pin the layer matching #{local_otp} (catalog: https://elixir-aws-lambda.dev/layers/)"}
        end
      end

    arch_result =
      case {f.arch, expected_arch} do
        {nil, _} ->
          []

        {a, nil} ->
          [{:ok, "#{file}: architecture #{a}", nil}]

        {a, a} ->
          [{:ok, "#{file}: architecture #{a}", nil}]

        {a, e} ->
          [
            {:warn, "#{file}: architecture #{a} but doctor was asked about #{e}",
             "pass --arch #{a} to check against the matching layer"}
          ]
      end

    runtime_result =
      case f.runtime do
        nil -> []
        "provided.al2023" -> []
        other -> [{:error, "#{file}: runtime #{other}", "Mayfly needs provided.al2023"}]
      end

    otp_result ++ arn_results ++ arch_result ++ runtime_result
  end

  # Generated templates embed the whole catalog map (every major, arch and
  # region); only the entries the file itself selects (its OTP major and
  # architecture) are relevant, and one line per distinct layer name is enough.
  defp relevant_layers(f) do
    f.layer_arns
    |> Enum.filter(fn arn ->
      name = arn |> String.split(":layer:") |> List.last()

      (is_nil(f.otp_major) or String.starts_with?(name, "mayfly-erlang-#{f.otp_major}-")) and
        (is_nil(f.arch) or String.contains?(name, "-#{f.arch}:"))
    end)
    |> Enum.uniq_by(fn arn -> arn |> String.split(":layer:") |> List.last() end)
  end

  defp arch_patterns(:sam),
    do: [
      ~r/Architecture:\s*\n\s*Type: String\s*\n\s*Default:\s*(arm64|x86_64)/m,
      ~r/Architectures:\s*\[?\s*(arm64|x86_64)/
    ]

  defp arch_patterns(:terraform),
    do: [
      ~r/variable "architecture"[^}]*default\s*=\s*"(arm64|x86_64)"/s,
      ~r/architectures\s*=\s*\["(arm64|x86_64)"\]/
    ]

  defp arch_patterns(:cdk), do: [~r/arch:\s*"(arm64|x86_64)"/, ~r/Architecture\.(ARM_64|X86_64)/]

  defp otp_patterns(:sam), do: [~r/OtpMajor:\s*\n\s*Type: String\s*\n\s*Default:\s*"?(\d\d)"?/m]
  defp otp_patterns(:terraform), do: [~r/variable "otp_major"[^}]*default\s*=\s*"(\d\d)"/s]
  defp otp_patterns(:cdk), do: [~r/otpMajor:\s*"(\d\d)"/]

  defp handler_patterns(:sam),
    do: [
      ~r/Handler:\s*\n\s*Type: String\s*\n\s*Default:\s*([A-Z][\w.]+)/m,
      ~r/Handler:\s*([A-Z][\w.]+)/
    ]

  defp handler_patterns(:terraform), do: [~r/variable "handler"[^}]*default\s*=\s*"([\w.]+)"/s]
  defp handler_patterns(:cdk), do: [~r/handler:\s*"([\w.]+)"/]

  defp first(content, patterns) do
    Enum.find_value(patterns, fn re ->
      case Regex.run(re, content) do
        [_, v] -> normalise(v)
        _ -> nil
      end
    end)
  end

  defp normalise("ARM_64"), do: "arm64"
  defp normalise("X86_64"), do: "x86_64"
  defp normalise(v), do: v

  defp short(arn), do: arn |> String.split(":layer:") |> List.last()
  defp arch_note(arch, nil), do: " (#{arch})"
  defp arch_note(arch, arch), do: " (#{arch})"
  defp arch_note(arch, expected), do: " (#{arch}; doctor asked about #{expected})"
end
