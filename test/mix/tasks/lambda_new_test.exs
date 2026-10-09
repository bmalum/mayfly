defmodule Mix.Tasks.Lambda.NewTest do
  # Uses the Mix shell and the file system.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Mix.Tasks.Lambda.New

  test "render/2 replaces every placeholder" do
    assigns = %{
      function_name: "hello-app",
      module: "HelloApp",
      arch: "arm64",
      otp: "28",
      region: "eu-west-1"
    }

    out =
      New.render(
        "__FUNCTION_NAME__ __HANDLER__ __ARCH__ __OTP__ __REGION__ __STACK_CLASS__",
        assigns
      )

    assert out == "hello-app HelloApp.Handler arm64 28 eu-west-1 HelloAppStack"
  end

  test "http_api_blocks/2 keeps or strips marked blocks in YAML, HCL and TS comment styles" do
    yaml = "a\n  # mayfly-http-api:begin\n  Api: x\n  # mayfly-http-api:end\nb\n"
    ts = "a\n// mayfly-http-api:begin\nconst api = 1;\n// mayfly-http-api:end\nb\n"
    assert New.http_api_blocks(yaml, false) == "a\nb\n"
    assert New.http_api_blocks(yaml, true) == "a\n  Api: x\nb\n"
    assert New.http_api_blocks(ts, false) == "a\nb\n"
    assert New.http_api_blocks(ts, true) == "a\nconst api = 1;\nb\n"
  end

  test "templates carry http-api blocks in all three flavours" do
    dir = New.templates_dir()

    for f <- ["sam/template.yaml", "terraform/main.tf", "cdk/bin/app.ts"] do
      content = File.read!(Path.join(dir, f))
      assert content =~ "mayfly-http-api:begin", f
      refute New.http_api_blocks(content, false) =~ ~r/HttpApi|apigatewayv2/, f
      assert New.http_api_blocks(content, true) =~ ~r/HttpApi|apigatewayv2/, f
    end
  end

  test "templates ship with rendered layer maps for every public region" do
    dir = New.templates_dir()

    for f <- ["sam/template.yaml", "terraform/locals.tf", "cdk/lib/mayfly-function.ts"] do
      content = File.read!(Path.join(dir, f))
      assert content =~ "eu-central-1", f
      assert content =~ "us-east-1", f
      assert content =~ ~r/mayfly-erlang-27-[\d-]+-arm64/, f
      refute content =~ "mayfly_layers = {}", f
    end
  end

  test "generates a project with an infra folder", %{tmp_dir: tmp} do
    Mix.shell(Mix.Shell.Process)
    path = Path.join(tmp, "demo_fn")

    try do
      New.generate(path,
        iac: "terraform",
        arch: "x86_64",
        otp: "27",
        region: "us-east-1",
        mayfly: "path:/x/mayfly"
      )
    after
      Mix.shell(Mix.Shell.IO)
    end

    assert File.read!(Path.join(path, "mix.exs")) =~ ~s(app: :demo_fn)
    assert File.read!(Path.join(path, "mix.exs")) =~ ~s({:mayfly, path: "/x/mayfly"})
    assert File.read!(Path.join(path, "mix.exs")) =~ "handler: DemoFn.Handler, layer: true"
    assert File.read!(Path.join(path, "lib/demo_fn/handler.ex")) =~ "defmodule DemoFn.Handler"
    assert File.read!(Path.join(path, ".tool-versions")) =~ ~r/^erlang 27\.\d+/
    assert File.read!(Path.join(path, "infra/variables.tf")) =~ ~s(default = "demo-fn")
    assert File.read!(Path.join(path, "infra/variables.tf")) =~ ~s(default     = "DemoFn.Handler")
    assert File.read!(Path.join(path, "infra/variables.tf")) =~ ~s(default = "x86_64")
    assert File.read!(Path.join(path, "infra/variables.tf")) =~ ~s(default = "us-east-1")
    refute File.read!(Path.join(path, "infra/locals.tf")) =~ "__"
    assert File.read!(Path.join(path, "README.md")) =~ "terraform apply"
  end

  test "rejects bad names and options", %{tmp_dir: tmp} do
    assert_raise Mix.Error, ~r/--iac/, fn -> New.generate(Path.join(tmp, "a"), iac: "pulumi") end
    assert_raise Mix.Error, ~r/Project name/, fn -> New.generate(Path.join(tmp, "1bad"), []) end
    File.mkdir_p!(Path.join(tmp, "full")) && File.write!(Path.join(tmp, "full/x"), "")
    assert_raise Mix.Error, ~r/not empty/, fn -> New.generate(Path.join(tmp, "full"), []) end
  end
end
