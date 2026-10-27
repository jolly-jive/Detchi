defmodule Detchi.HousekeeperTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Detchi.Config
  alias Detchi.Config.{Probe, Target}
  alias Detchi.Housekeeper

  @moduletag :tmp_dir
  @moduletag :capture_log

  @target %Target{
    name: "core1",
    host: "192.0.2.1",
    address: {192, 0, 2, 1},
    family: :auto,
    probes: [%Probe{name: "ping", protocol: :icmp, interval_ms: 60_000, timeout_ms: 1000}]
  }

  @lines ~s({"a":1}\n{"b":2}\n)
  # 2026-10-20T12:00:00Z
  @mtime 1_792_497_600

  defp ts(text),
    do: :calendar.rfc3339_to_system_time(String.to_charlist(text), unit: :microsecond)

  defp config(dir, opts),
    do: %Config{
      data_dir: dir,
      retention_days: Keyword.get(opts, :retention_days, 1827),
      compression: Keyword.get(opts, :compression, :gzip),
      resolve_interval_ms: 300_000,
      targets: [@target]
    }

  # The clock of the Housekeeper, set by the test. Returns after the sweep
  # at start is done.
  defp start_housekeeper(dir, now, opts \\ []) do
    clock = :atomics.new(1, signed: true)
    :atomics.put(clock, 1, ts(now))

    opts =
      [
        config: config(dir, opts),
        name: nil,
        clock: fn -> :atomics.get(clock, 1) end,
        offset: ~c"+09:00"
      ]
      |> Keyword.merge(Keyword.take(opts, [:sweep_interval_ms]))

    housekeeper = start_supervised!({Housekeeper, opts})
    :sys.get_state(housekeeper)
    {housekeeper, fn now -> :atomics.put(clock, 1, ts(now)) end}
  end

  defp put(dir, name, content \\ @lines) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    File.touch!(path, @mtime)
    path
  end

  defp ls(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  # A call makes sure the casts before it are done.
  defp done(housekeeper), do: :sys.get_state(housekeeper)

  describe "compression" do
    test "gzip: the file is replaced, with its mtime", %{tmp_dir: dir} do
      {housekeeper, _} = start_housekeeper(dir, "2026-10-27T10:00:00+09:00")
      path = put(dir, "core1/core1-2026-10-26.jsonl")

      Housekeeper.file_closed(housekeeper, path)
      done(housekeeper)

      assert ls(dir) == ["core1", "core1/core1-2026-10-26.jsonl.gz"]
      gz = path <> ".gz"
      assert :zlib.gunzip(File.read!(gz)) == @lines
      assert %{mtime: @mtime, mode: mode} = File.stat!(gz, time: :posix)
      assert Bitwise.band(mode, 0o777) == 0o644
    end

    test "zstd", %{tmp_dir: dir} do
      {housekeeper, _} = start_housekeeper(dir, "2026-10-27T10:00:00+09:00", compression: :zstd)
      lines = Enum.map_join(1..20_000, &~s({"n":#{&1}}\n))
      path = put(dir, "core1/core1-2026-10-26.jsonl", lines)

      Housekeeper.file_closed(housekeeper, path)
      done(housekeeper)

      assert ls(dir) == ["core1", "core1/core1-2026-10-26.jsonl.zst"]
      assert IO.iodata_to_binary(:zstd.decompress(File.read!(path <> ".zst"))) == lines
      assert File.stat!(path <> ".zst", time: :posix).mtime == @mtime
    end

    test "a compressed file left with the .jsonl is made again", %{tmp_dir: dir} do
      {housekeeper, _} = start_housekeeper(dir, "2026-10-27T10:00:00+09:00")
      path = put(dir, "core1/core1-2026-10-26.jsonl")
      put(dir, "core1/core1-2026-10-26.jsonl.gz", "broken")

      Housekeeper.file_closed(housekeeper, path)
      done(housekeeper)

      assert ls(dir) == ["core1", "core1/core1-2026-10-26.jsonl.gz"]
      assert :zlib.gunzip(File.read!(path <> ".gz")) == @lines
    end

    test "a file done already is skipped", %{tmp_dir: dir} do
      {housekeeper, _} = start_housekeeper(dir, "2026-10-27T10:00:00+09:00")
      path = put(dir, "core1/core1-2026-10-26.jsonl")

      Housekeeper.file_closed(housekeeper, path)
      Housekeeper.file_closed(housekeeper, path)

      assert capture_log(fn -> done(housekeeper) end) == ""
      assert ls(dir) == ["core1", "core1/core1-2026-10-26.jsonl.gz"]
    end

    test "on failure, the .jsonl is left and the .part deleted", %{tmp_dir: dir} do
      {housekeeper, _} = start_housekeeper(dir, "2026-10-27T10:00:00+09:00")
      path = put(dir, "core1/core1-2026-10-26.jsonl")
      # The rename fails on a directory that is not empty.
      put(dir, "core1/core1-2026-10-26.jsonl.gz/x")

      log =
        capture_log(fn ->
          Housekeeper.file_closed(housekeeper, path)
          done(housekeeper)
        end)

      assert log =~ "cannot compress #{path}"
      assert File.read!(path) == @lines
      refute File.exists?(path <> ".gz.part")
    end

    test "compress_before/3 takes the files before the date", %{tmp_dir: dir} do
      {housekeeper, _} = start_housekeeper(dir, "2026-10-27T10:00:00+09:00")
      put(dir, "core1/core1-2026-10-25.jsonl")
      put(dir, "core1/core1-2026-10-26.jsonl")
      put(dir, "core1/core1-2026-10-27.jsonl")

      Housekeeper.compress_before(housekeeper, "core1", "2026-10-27")
      done(housekeeper)

      assert ls(dir) == [
               "core1",
               "core1/core1-2026-10-25.jsonl.gz",
               "core1/core1-2026-10-26.jsonl.gz",
               "core1/core1-2026-10-27.jsonl"
             ]
    end
  end

  describe "sweep" do
    test "at start", %{tmp_dir: dir} do
      # Kept: today and the 3 days before.
      for name <- [
            "core1/core1-2026-10-23.jsonl.gz",
            "core1/core1-2026-10-23.jsonl.zst",
            "core1/core1-2026-10-24.jsonl.gz",
            "core1/core1-2026-10-24.jsonl.zst",
            "core1/core1-2026-10-25.jsonl",
            "core1/core1-2026-10-26.jsonl",
            "core1/core1-2026-10-27.jsonl",
            "core1/core1-2026-10-26.jsonl.gz.part",
            "old/old-2026-10-23.jsonl",
            "old/old-2026-10-26.jsonl",
            "old/old-2026-10-27.jsonl",
            "gone/gone-2026-10-01.jsonl.gz",
            # Not by the naming rule.
            "core1/core1-2026-02-30.jsonl",
            "core1/core1-2026-10-01.jsonl.bak",
            "core1/core1-2026-10-01.jsonl.part",
            "core1/other-2026-10-01.jsonl",
            "core1/README",
            "Upper/Upper-2026-10-01.jsonl"
          ],
          do: put(dir, name)

      File.mkdir_p!(Path.join(dir, "empty"))

      start_housekeeper(dir, "2026-10-27T10:00:00+09:00", retention_days: 3)

      assert ls(dir) == [
               "Upper",
               "Upper/Upper-2026-10-01.jsonl",
               "core1",
               "core1/README",
               "core1/core1-2026-02-30.jsonl",
               "core1/core1-2026-10-01.jsonl.bak",
               "core1/core1-2026-10-01.jsonl.part",
               "core1/core1-2026-10-24.jsonl.gz",
               "core1/core1-2026-10-24.jsonl.zst",
               # Before yesterday, for a target in the config.
               "core1/core1-2026-10-25.jsonl.gz",
               "core1/core1-2026-10-26.jsonl",
               "core1/core1-2026-10-27.jsonl",
               "core1/other-2026-10-01.jsonl",
               "old",
               # Before today, for a target not in the config.
               "old/old-2026-10-26.jsonl.gz",
               "old/old-2026-10-27.jsonl"
             ]
    end

    test "the directory of a target in the config stays", %{tmp_dir: dir} do
      put(dir, "core1/core1-2026-10-01.jsonl.gz")

      start_housekeeper(dir, "2026-10-27T10:00:00+09:00", retention_days: 3)

      assert ls(dir) == ["core1"]
    end

    test "no data_dir yet", %{tmp_dir: dir} do
      data_dir = Path.join(dir, "data")

      assert capture_log(fn -> start_housekeeper(data_dir, "2026-10-27T10:00:00+09:00") end) ==
               ""
    end

    test "again after the interval", %{tmp_dir: dir} do
      {housekeeper, set_clock} =
        start_housekeeper(dir, "2026-10-27T10:00:00+09:00",
          retention_days: 3,
          sweep_interval_ms: 100
        )

      put(dir, "core1/core1-2026-10-24.jsonl.gz")
      set_clock.("2026-10-28T10:00:00+09:00")
      Process.sleep(300)
      done(housekeeper)

      assert ls(dir) == ["core1"]
    end
  end
end
