defmodule Detchi.EscriptTest do
  # Builds ./detchi and runs it, as it is shipped (docs/basic-design.md, 3).
  use ExUnit.Case, async: false

  @moduletag :escript

  @escript Path.expand("detchi")
  @sample Path.expand("test/fixtures/config/sample.yml")

  setup_all do
    {output, 0} = System.cmd("mix", ["escript.build"], stderr_to_stdout: true)
    assert output =~ "Generated escript"
    :ok
  end

  defp detchi(args, config) do
    System.cmd(@escript, args, env: [{"DETCHI_CONFIG", config}], stderr_to_stdout: true)
  end

  test "check-config exits with 0 for a valid config and 1 for an invalid one" do
    assert {"#{@sample}: ok (3 targets, 8 probes)\n", 0} == detchi(["check-config"], @sample)

    assert {"/nonexistent: error: cannot read the file (enoent)\n/nonexistent: 1 error\n", 1} ==
             detchi(["check-config"], "/nonexistent")
  end

  @tag :tmp_dir
  test "status exits with 0 when every target is ok and 1 when not", %{tmp_dir: dir} do
    config = Path.join(dir, "detchi.yml")

    File.write!(config, """
    data_dir: #{dir}/data
    targets: [{ name: t, host: 192.0.2.1, probes: [{ name: ping, protocol: icmp }] }]
    """)

    assert {"stale  t  never written" <> _, 1} = detchi(["status"], config)

    File.mkdir_p!(Path.join(dir, "data/t"))
    File.touch!(Path.join(dir, "data/t/t-#{Date.utc_today()}.jsonl"))
    assert {"ok     t  last " <> _, 0} = detchi(["status"], config)
    assert {"", 0} = detchi(["status", "-q"], config)
  end

  test "a usage error exits with 2" do
    assert {"Usage: detchi <command>" <> _, 2} = detchi(["bogus"], @sample)
  end

  for signal <- ["TERM", "HUP"] do
    test "run keeps running and exits with 0 on SIG#{signal}" do
      port =
        Port.open({:spawn_executable, @escript}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["run"],
          env: [{~c"DETCHI_CONFIG", String.to_charlist(@sample)}]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      refute_receive {^port, {:exit_status, _}}, 2_000

      {_, 0} = System.cmd("kill", ["-#{unquote(signal)}", Integer.to_string(os_pid)])
      assert_receive {^port, {:exit_status, 0}}, 10_000
    end
  end
end
