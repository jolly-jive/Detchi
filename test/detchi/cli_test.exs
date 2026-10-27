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
            ["check-config", "--fingerprints", "extra"],
            ["--fingerprints", "check-config"],
            ["run", "--fingerprints"],
            ["run", "x"],
            ["status", "--quiet"],
            ["status", "-q", "extra"],
            ["-q", "status"]
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

    test "--fingerprints prints the fingerprint and canonical JSON of each target" do
      System.put_env("DETCHI_CONFIG", @sample)
      assert {0, stdout, ""} = run(["check-config", "--fingerprints"])

      {:ok, config, []} = Detchi.Config.load(@sample)

      expected =
        Enum.map(config.targets, fn target ->
          "#{target.name} #{Detchi.Config.Fingerprint.hash(target)}\n" <>
            "#{target.name} #{Detchi.Config.Fingerprint.canonical(target)}\n"
        end)

      assert stdout == Enum.join(expected) <> "#{@sample}: ok (3 targets, 8 probes)\n"
      assert stdout =~ ~r/^sw1 sha256:[0-9a-f]{64}$/m
      refute stdout =~ "s3cr3t-community"
    end

    test "--fingerprints prints nothing more when the config has errors", %{tmp_dir: dir} do
      path = Path.join(dir, "detchi.yml")
      File.write!(path, "targets: []\n")
      System.put_env("DETCHI_CONFIG", path)

      assert run(["check-config", "--fingerprints"]) == run(["check-config"])
    end

    test "does not start the application" do
      System.put_env("DETCHI_CONFIG", @sample)
      assert {0, _, _} = run(["check-config"])

      refute List.keymember?(Application.started_applications(), :detchi, 0)
      assert Process.whereis(Detchi.Supervisor) == nil
    end
  end

  test "status does not start the application" do
    System.put_env("DETCHI_CONFIG", @sample)
    assert {status, _, _} = run(["status", "-q"])
    assert status in [0, 1]

    refute List.keymember?(Application.started_applications(), :detchi, 0)
    assert Process.whereis(Detchi.Supervisor) == nil
  end

  test "run exits with 1 on a config error, without starting the application" do
    System.put_env("DETCHI_CONFIG", "/nonexistent/detchi.yml")

    assert {1, "", "/nonexistent/detchi.yml: error: cannot read the file (enoent)\n"} =
             run(["run"])

    refute List.keymember?(Application.started_applications(), :detchi, 0)
  end

  test "run checks ICMP sockets of the families the ICMP probes use" do
    {:ok, config, []} = Detchi.Config.load(@sample)
    test = self()

    checking = fn result ->
      fn family ->
        send(test, {:checked, family})
        result
      end
    end

    assert Detchi.CLI.Run.check_icmp(config, checking.(:ok)) == :ok
    assert_received {:checked, :inet}
    assert_received {:checked, :inet6}

    assert Detchi.CLI.Run.check_icmp(config, checking.({:error, :eacces})) ==
             {:error,
              "cannot open an ICMP socket (eacces); " <>
                "net.ipv4.ping_group_range does not include the groups of this user"}

    assert Detchi.CLI.Run.check_icmp(%{config | targets: []}, checking.({:error, :eacces})) ==
             :ok
  end
end
