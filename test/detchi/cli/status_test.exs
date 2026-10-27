defmodule Detchi.CLI.StatusTest do
  # Changes DETCHI_CONFIG, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Detchi.CLI.Status

  @moduletag :tmp_dir

  # 2026-10-24T01:23:45+09:00
  @now 1_792_772_625

  setup %{tmp_dir: dir} do
    on_exit(fn -> System.delete_env("DETCHI_CONFIG") end)
    data_dir = Path.join(dir, "data")
    config = Path.join(dir, "detchi.yml")

    File.write!(config, """
    data_dir: #{data_dir}
    targets:
      - name: core1
        host: 192.0.2.1
        probes:
          - { name: ping, protocol: icmp }
          - { name: if, protocol: snmp, interval: 300s, timeout: 5s, oids: [1.3.6.1.2.1.1.3.0] }
        snmp: { credential: c }
      - { name: sw1, host: 192.0.2.2, probes: [{ name: ping, protocol: icmp }] }
      - { name: switch-2, host: 192.0.2.3, probes: [{ name: ping, protocol: icmp, interval: 5m }] }
    credentials:
      c: { version: v2c, community: public }
    """)

    System.put_env("DETCHI_CONFIG", config)
    %{data_dir: data_dir, config: config}
  end

  defp status(opts \\ []) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            send(parent, {:status, Status.run([now: @now, offset: ~c"+09:00"] ++ opts)})
          end)

        send(parent, {:stdout, stdout})
      end)

    assert_received {:status, status}
    assert_received {:stdout, stdout}
    {status, stdout, stderr}
  end

  defp touch(data_dir, target, name, mtime) do
    path = Path.join([data_dir, target, name])
    File.mkdir_p!(Path.dirname(path))
    File.touch!(path, mtime)
    path
  end

  test "exits with 0 when every target was written within its limit", %{data_dir: d} do
    touch(d, "core1", "core1-2026-10-24.jsonl", @now - 12)
    touch(d, "sw1", "sw1-2026-10-24.jsonl", @now - 121)
    touch(d, "switch-2", "switch-2-2026-10-24.jsonl", @now - 3)

    assert {0, stdout, ""} = status()

    assert stdout == """
           ok     core1     last 2026-10-24T01:23:33+09:00  age 12s   limit 125s
           ok     sw1       last 2026-10-24T01:21:44+09:00  age 121s  limit 121s
           ok     switch-2  last 2026-10-24T01:23:42+09:00  age 3s    limit 601s
           """
  end

  test "exits with 1 when a target is stale or never written", %{data_dir: d} do
    touch(d, "core1", "core1-2026-10-24.jsonl", @now - 12)
    touch(d, "sw1", "sw1-2026-10-24.jsonl", @now - 1135)

    assert {1, stdout, ""} = status()

    assert stdout == """
           ok     core1     last 2026-10-24T01:23:33+09:00  age 12s    limit 125s
           stale  sw1       last 2026-10-24T01:04:50+09:00  age 1135s  limit 121s
           stale  switch-2  never written                              limit 601s
           """
  end

  test "quiet prints only the stale targets, as wide as without it", %{data_dir: d} do
    touch(d, "core1", "core1-2026-10-24.jsonl", @now - 1135)
    touch(d, "sw1", "sw1-2026-10-24.jsonl", @now - 12)

    assert {1, stdout, ""} = status(quiet: true)

    assert stdout == """
           stale  core1     last 2026-10-24T01:04:50+09:00  age 1135s  limit 125s
           stale  switch-2  never written                              limit 601s
           """

    touch(d, "core1", "core1-2026-10-24.jsonl", @now)
    touch(d, "switch-2", "switch-2-2026-10-24.jsonl", @now)
    assert {0, "", ""} = status(quiet: true)
  end

  test "every target is never written when there is no data_dir", %{data_dir: d} do
    assert {1, stdout, ""} = status()
    refute File.exists?(d)

    # As wide as a line with a time, but no age.
    pad = String.duplicate(" ", 19)

    assert stdout == """
           stale  core1     never written#{pad}  limit 125s
           stale  sw1       never written#{pad}  limit 121s
           stale  switch-2  never written#{pad}  limit 601s
           """
  end

  test "takes the latest mtime of the files of the two latest dates", %{data_dir: d} do
    # Just after midnight: yesterday's file was written after today's.
    touch(d, "sw1", "sw1-2026-10-24.jsonl", @now - 300)
    touch(d, "sw1", "sw1-2026-10-23.jsonl", @now - 10)
    # The same date, being compressed.
    touch(d, "core1", "core1-2026-10-24.jsonl.gz", @now - 300)
    touch(d, "core1", "core1-2026-10-24.jsonl", @now - 20)
    # Older dates, and files that do not match the rule, are not looked at.
    touch(d, "switch-2", "switch-2-2026-10-24.jsonl", @now - 1000)
    touch(d, "switch-2", "switch-2-2026-10-23.jsonl.zst", @now - 2000)
    touch(d, "switch-2", "switch-2-2026-10-22.jsonl.gz", @now)
    touch(d, "switch-2", "switch-2-2026-10-24.jsonl.gz.part", @now)
    touch(d, "switch-2", "switch-2-2026-10-25.txt", @now)
    touch(d, "switch-2", "sw1-2026-10-25.jsonl", @now)
    touch(d, "switch-2", "switch-2-2026-02-30.jsonl", @now)

    assert {1, stdout, ""} = status()
    assert stdout =~ ~r/^ok     core1     .* age 20s /m
    assert stdout =~ ~r/^ok     sw1       .* age 10s /m
    assert stdout =~ ~r/^stale  switch-2  .* age 1000s /m
  end

  test "an mtime in the future is taken as now", %{data_dir: d} do
    touch(d, "sw1", "sw1-2026-10-24.jsonl", @now + 3600)
    assert {1, stdout, ""} = status()
    assert stdout =~ "ok     sw1       last 2026-10-24T02:23:45+09:00  age 0s "
  end

  test "a directory that cannot be read goes to stderr and exits with 1", %{data_dir: d} do
    touch(d, "core1", "core1-2026-10-24.jsonl", @now)
    touch(d, "switch-2", "switch-2-2026-10-24.jsonl", @now)
    # A file where the directory should be.
    File.write!(Path.join(d, "sw1"), "")

    assert {1, stdout, stderr} = status()

    assert stdout == """
           ok     core1     last 2026-10-24T01:23:45+09:00  age 0s  limit 125s
           ok     switch-2  last 2026-10-24T01:23:45+09:00  age 0s  limit 601s
           """

    assert stderr == "#{d}/sw1: error: cannot read the directory (enotdir)\n"
  end

  test "config errors go to stderr, without the credentials", %{config: config} do
    File.write!(config, "targets: []\ncredentials: { c: { version: v2c, community:s3cr3t } }\n")
    assert {1, "", stderr} = status()
    assert stderr =~ "#{config}:1:10: error: targets: must not be empty\n"
    assert stderr =~ ~r/#{config}: \d+ errors?\n\z/
    refute stderr =~ "s3cr3t"
  end

  test "config warnings go to stderr, and do not change the exit status", %{config: config} do
    File.write!(config, """
    data_dir: #{Path.dirname(config)}
    targets:
      - { name: t, host: h, probes: [{ name: n, protocol: udp, service: ntp, interval: 2s }] }
    """)

    touch(Path.dirname(config), "t", "t-2026-10-24.jsonl", @now)
    assert {0, "ok     t  last " <> _, stderr} = status()
    assert stderr =~ ~r/\A#{config}:3:\d+: warning: /
  end

  describe "limit_s/1" do
    defp target(probes) do
      %Detchi.Config.Target{
        name: "t",
        host: "h",
        family: :auto,
        probes:
          for {interval, timeout} <- probes do
            %Detchi.Config.Probe{
              name: "p",
              protocol: :icmp,
              interval_ms: interval,
              timeout_ms: timeout
            }
          end
      }
    end

    test "is twice the shortest interval and the longest timeout, at least 30s" do
      assert Status.limit_s(target([{60_000, 1_000}])) == 121
      assert Status.limit_s(target([{300_000, 5_000}, {60_000, 1_000}])) == 125
      assert Status.limit_s(target([{1_000, 500}])) == 30
    end

    test "rounds up to seconds" do
      assert Status.limit_s(target([{15_000, 200}])) == 31
      assert Status.limit_s(target([{15_000, 1_000}])) == 31
    end
  end
end
