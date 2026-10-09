defmodule Mix.Tasks.Lambda.IaCTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Mix.Tasks.Lambda.{IaC, New}

  defp generate(tmp, iac, extra \\ []) do
    Mix.shell(Mix.Shell.Process)
    path = Path.join(tmp, "p_#{iac}")

    try do
      New.generate(
        path,
        [iac: iac, arch: "arm64", otp: "27", region: "eu-central-1", mayfly: "path:/x"] ++ extra
      )
    after
      Mix.shell(Mix.Shell.IO)
    end

    path
  end

  test "discovers and inspects generated SAM, Terraform and CDK projects", %{tmp_dir: tmp} do
    for iac <- ["sam", "terraform", "cdk"] do
      path = generate(tmp, iac)
      [{kind, files}] = found = IaC.discover(path)
      assert kind == String.to_atom(iac), "#{iac}: #{inspect(found)}"
      f = IaC.inspect_files(kind, files)
      assert f.arch == "arm64", iac
      assert f.otp_major == "27", iac
      assert f.handler =~ ~r/^P[a-zA-Z]+\.Handler$/, "#{iac}: #{inspect(f.handler)}"
      # all three carry the full catalog map
      assert Enum.any?(f.layer_arns, &(&1 =~ "mayfly-erlang-27-" and &1 =~ "eu-central-1")), iac
    end
  end

  test "check/3 agrees with a matching toolchain and flags mismatches" do
    f = %{
      file: "template.yaml",
      kind: :sam,
      arch: "arm64",
      otp_major: "27",
      layer_arns: [
        "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      ],
      runtime: "provided.al2023",
      handler: "X.Handler"
    }

    results = IaC.check(f, "27.3.4.18", "arm64")
    assert Enum.all?(results, &match?({:ok, _, _}, &1)), inspect(results)
    assert length(results) == 3

    # alias ARN (major only) is accepted for any patch of that major
    alias_f = %{
      f
      | layer_arns: ["arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-27-arm64:4"]
    }

    assert [{:ok, _, _}, {:ok, label, _}, {:ok, _, _}] = IaC.check(alias_f, "27.3.4.18", nil)
    assert label =~ "alias"

    # wrong OTP major parameter and a pinned layer of another OTP are errors; a different arch is a warning
    bad =
      IaC.check(
        %{
          f
          | otp_major: "28",
            layer_arns: [
              "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
            ]
        },
        "27.3.4.18",
        "x86_64"
      )

    assert [{:error, otp_label, _}, {:error, arn_label, hint}, {:warn, _, _}] = bad
    assert otp_label =~ "OTP major 28"
    assert arn_label =~ "is OTP 28.5.0.7 but the toolchain is 27.3.4.18"
    assert hint =~ "mise use erlang@28.5.0.7"

    assert [{:error, _, "Mayfly needs provided.al2023"}] =
             IaC.check(
               %{f | arch: nil, otp_major: nil, layer_arns: [], runtime: "nodejs20.x"},
               "27.3.4.18",
               nil
             )
  end
end
