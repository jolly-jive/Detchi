defmodule Detchi.CLITest do
  # Changes DETCHI_CONFIG, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Detchi.CLI

  @sample Path.expand("test/fixtures/config/sample.yml")

  setup do
    on_exit(fn -> System.delete_env("DETCHI_CONFIG") end)
  end

  defp run(argv) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {:status, CLI.run(argv)}) end)
        send(parent, {:stdout, stdout})
      end)

    assert_received {:status, status}
    assert_received {:stdout, stdout}
    {status, stdout, stderr}
  end

  describe "usage" do
    test "--help and --version exit with 0" do
      assert {0, "Usage: detchi <command>" <> _, ""} = run(["--help"])
      assert {0, "Usage: detchi <command>" <> _, ""} = run(["-h"])
      assert {0, "detchi 0.1.0\n", ""} = run(["--version"])
    end

    test "no command, an unknown command or extra arguments exit with 2" do
      for argv <- [
            [],
            ["frobnicate"],
            ["check-config", "extra"],
            ["check-config", "--quiet"],
            ["run", "x"]
          ] do
        assert {2, "", "Usage: detchi <command>" <> _} = run(argv), inspect(argv)
      end
    end
  end

  describe "check-config" do
    @describetag :tmp_dir

    test "exits with 0 for a valid config", %{tmp_dir: _} do
      System.put_env("DETCHI_CONFIG", @sample)
      assert {0, stdout, ""} = run(["check-config"])
      assert stdout == "#{@sample}: ok (3 targets, 8 probes)\n"
    end

    test "prints warnings to stdout and still exits with 0", %{tmp_dir: dir} do
      path = Path.join(dir, "detchi.yml")

      File.write!(path, """
      targets:
        - { name: t, host: h, probes: [{ name: n, protocol: udp, service: ntp, interval: 2s }] }
      """)

      System.put_env("DETCHI_CONFIG", path)
      assert {0, stdout, ""} = run(["check-config"])

      assert stdout ==
               "#{path}:2:84: warning: targets[0].probes[0].interval: interval is shorter than 8s; " <>
                 "NTP servers you do not run may rate-limit or drop the queries\n" <>
                 "#{path}: ok (1 target, 1 probe)\n"
    end

    test "prints errors to stderr and exits with 1", %{tmp_dir: dir} do
      path = Path.join(dir, "detchi.yml")
      File.write!(path, "compression: xz\ntargets: []\n")
      System.put_env("DETCHI_CONFIG", path)

      assert {1, "", stderr} = run(["check-config"])

      assert stderr ==
               "#{path}:1:14: error: compression: must be one of: gzip, zstd\n" <>
                 "#{path}:2:10: error: targets: must not be empty\n" <>
                 "#{path}: 2 errors\n"
    end

    test "does not start the application" do
      System.put_env("DETCHI_CONFIG", @sample)
      assert {0, _, _} = run(["check-config"])

      refute List.keymember?(Application.started_applications(), :detchi, 0)
      assert Process.whereis(Detchi.Supervisor) == nil
    end
  end

  test "run exits with 1 on a config error, without starting the application" do
    System.put_env("DETCHI_CONFIG", "/nonexistent/detchi.yml")

    assert {1, "", "/nonexistent/detchi.yml: error: cannot read the file (enoent)\n"} =
             run(["run"])

    refute List.keymember?(Application.started_applications(), :detchi, 0)
  end
end
