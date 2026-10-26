defmodule Detchi.WriterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Detchi.Config.{Fingerprint, Probe, Target}
  alias Detchi.Writer

  @moduletag :tmp_dir
  @moduletag :capture_log

  @target %Target{
    name: "core1",
    host: "192.0.2.1",
    address: {192, 0, 2, 1},
    family: :auto,
    probes: [%Probe{name: "ping", protocol: :icmp, interval_ms: 60_000, timeout_ms: 1000}]
  }

  @version Mix.Project.config()[:version]

  defp ts(text),
    do: :calendar.rfc3339_to_system_time(String.to_charlist(text), unit: :microsecond)

  # The clock of the Writer, set by the test.
  defp start_writer(dir, now, opts \\ []) do
    clock = :atomics.new(1, signed: true)
    :atomics.put(clock, 1, ts(now))

    opts =
      [
        target: @target,
        data_dir: dir,
        housekeeper: self(),
        grace_ms: 60_000,
        clock: fn -> :atomics.get(clock, 1) end,
        offset: ~c"+09:00"
      ]
      |> Keyword.merge(opts)

    writer = start_supervised!({Writer, opts})
    {writer, fn now -> :atomics.put(clock, 1, ts(now)) end}
  end

  defp ping(ts),
    do: %{
      ts: ts(ts),
      probe: "ping",
      protocol: :icmp,
      addr: {192, 0, 2, 1},
      status: :ok,
      rtt_us: 1234
    }

  # Lines of a file, decoded; a call makes sure the casts before it are done.
  defp lines(writer, dir, date) do
    :sys.get_state(writer)

    Writer.path(dir, "core1", date)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&:json.decode/1)
  end

  defp event(line), do: line["event"] || line["probe"]

  test "writes start first, then lines to the file of the date of their ts", %{tmp_dir: dir} do
    {writer, _} = start_writer(dir, "2026-10-23T21:00:00.000000+09:00")

    assert :ok = Writer.start(writer, {192, 0, 2, 1})
    Writer.write(writer, ping("2026-10-23T21:00:00.123456+09:00"))

    assert [start, ping] = lines(writer, dir, "2026-10-23")

    assert start == %{
             "v" => 1,
             "ts" => "2026-10-23T21:00:00.000000+09:00",
             "target" => "core1",
             "event" => "start",
             "version" => @version,
             "config_hash" => Fingerprint.hash(@target),
             "addr" => "192.0.2.1"
           }

    assert ping["ts"] == "2026-10-23T21:00:00.123456+09:00"
    assert ping["target"] == "core1"

    assert File.stat!(Path.join(dir, "core1")).mode |> Bitwise.band(0o777) == 0o755

    assert File.stat!(Writer.path(dir, "core1", "2026-10-23")).mode |> Bitwise.band(0o777) ==
             0o644
  end

  test "leaves out addr in start when the host has not resolved", %{tmp_dir: dir} do
    {writer, _} = start_writer(dir, "2026-10-23T21:00:00.000000+09:00")

    Writer.start(writer, nil)

    assert [start] = lines(writer, dir, "2026-10-23")
    refute Map.has_key?(start, "addr")
  end

  test "appends to the file of today, ending a cut-off line first", %{tmp_dir: dir} do
    path = Writer.path(dir, "core1", "2026-10-23")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"v":1,"ts":"2026-10-23T20:00:00.000000+09:00"}\n{"v":1,"ts":"2026-10))

    {writer, _} = start_writer(dir, "2026-10-23T21:00:00.000000+09:00")
    Writer.start(writer, {192, 0, 2, 1})
    :sys.get_state(writer)

    assert [_, "{\"v\":1,\"ts\":\"2026-10", start, ""] =
             path |> File.read!() |> String.split("\n")

    assert start =~ ~s("event":"start")
  end

  test "opens the file of a new date with file_opened and closes the old one later",
       %{tmp_dir: dir} do
    {writer, set_clock} =
      start_writer(dir, "2026-10-23T23:59:00.000000+09:00", grace_ms: 100)

    Writer.start(writer, {192, 0, 2, 1})
    Writer.write(writer, ping("2026-10-23T23:59:59.900000+09:00"))
    set_clock.("2026-10-24T00:00:00.100000+09:00")
    Writer.write(writer, ping("2026-10-24T00:00:00.000000+09:00"))
    # A result of a request sent before midnight still goes to its date.
    Writer.write(writer, ping("2026-10-23T23:59:59.950000+09:00"))

    assert ["start", "ping", "ping"] = lines(writer, dir, "2026-10-23") |> Enum.map(&event/1)
    assert [opened, ping] = lines(writer, dir, "2026-10-24")

    assert opened == %{
             "v" => 1,
             "ts" => "2026-10-24T00:00:00.000000+09:00",
             "target" => "core1",
             "event" => "file_opened",
             "version" => @version,
             "config_hash" => Fingerprint.hash(@target),
             "addr" => "192.0.2.1"
           }

    assert ping["ts"] == "2026-10-24T00:00:00.000000+09:00"

    closed = Writer.path(dir, "core1", "2026-10-23")
    assert_receive {:"$gen_cast", {:file_closed, ^closed}}, 1000

    # The file of a closed date is not written again; the line is dropped.
    log =
      capture_log(fn ->
        Writer.write(writer, ping("2026-10-23T23:59:59.990000+09:00"))
        :sys.get_state(writer)
      end)

    assert log =~ "core1: dropping lines: the file of 2026-10-23 is closed"
    assert length(lines(writer, dir, "2026-10-23")) == 3

    set_clock.("2026-10-24T00:01:00.000000+09:00")
    Writer.write(writer, ping("2026-10-24T00:01:00.000000+09:00"))

    assert [_, _, dropped, _] = lines(writer, dir, "2026-10-24")

    assert dropped == %{
             "v" => 1,
             "ts" => "2026-10-24T00:01:00.000000+09:00",
             "target" => "core1",
             "event" => "dropped",
             "count" => 1,
             "first_ts" => "2026-10-23T23:59:59.990000+09:00",
             "last_ts" => "2026-10-23T23:59:59.990000+09:00"
           }
  end

  test "drops lines of dates before it started", %{tmp_dir: dir} do
    {writer, _} = start_writer(dir, "2026-10-24T00:00:01.000000+09:00")
    Writer.start(writer, {192, 0, 2, 1})

    Writer.write(writer, ping("2026-10-23T23:59:59.000000+09:00"))
    Writer.write(writer, ping("2026-10-24T00:00:01.100000+09:00"))

    refute File.exists?(Writer.path(dir, "core1", "2026-10-23"))

    assert [%{"event" => "start"}, %{"event" => "dropped", "count" => 1}, %{"probe" => "ping"}] =
             lines(writer, dir, "2026-10-24")
  end

  test "counts lines it cannot write and writes dropped when it can again", %{tmp_dir: dir} do
    {writer, set_clock} = start_writer(dir, "2026-10-23T21:00:00.000000+09:00")
    File.chmod!(dir, 0o555)

    log =
      capture_log(fn ->
        Writer.start(writer, {192, 0, 2, 1})
        Writer.write(writer, ping("2026-10-23T21:00:00.100000+09:00"))
        Writer.write(writer, ping("2026-10-23T21:01:00.100000+09:00"))
        :sys.get_state(writer)
      end)

    assert log =~
             "core1: dropping lines: cannot write #{dir}/core1/core1-2026-10-23.jsonl (eacces)"

    File.chmod!(dir, 0o755)
    set_clock.("2026-10-23T21:02:00.000000+09:00")
    Writer.write(writer, ping("2026-10-23T21:02:00.100000+09:00"))

    # The first file of the Writer is opened by the dropped line, not by
    # start, so it begins with file_opened.
    assert [opened, dropped, ping] = lines(writer, dir, "2026-10-23")
    assert opened["event"] == "file_opened"
    assert dropped["count"] == 3
    assert dropped["first_ts"] == "2026-10-23T21:00:00.000000+09:00"
    assert dropped["last_ts"] == "2026-10-23T21:01:00.100000+09:00"
    assert ping["ts"] == "2026-10-23T21:02:00.100000+09:00"
  end

  test "writes events, following the address", %{tmp_dir: dir} do
    {writer, _} = start_writer(dir, "2026-10-23T21:00:00.000000+09:00", grace_ms: 0)

    Writer.start(writer, nil)

    Writer.event(writer, :resolve_failed, %{
      host: "core1.example.net",
      error: {:resolve, :nxdomain}
    })

    Writer.event(writer, :addr_changed, %{host: "core1.example.net", new: {192, 0, 2, 1}})
    Writer.event(writer, :clock_stepped, %{offset_us: -2_000_000})

    assert [_, failed, changed, stepped] = lines(writer, dir, "2026-10-23")

    assert %{"error" => %{"reason" => "resolve", "errno" => "nxdomain"}} = failed
    refute Map.has_key?(failed, "addr")
    assert %{"new" => "192.0.2.1"} = changed
    refute Map.has_key?(changed, "old")
    assert %{"offset_us" => -2_000_000} = stepped
    assert %{addr: {192, 0, 2, 1}} = :sys.get_state(writer)
  end

  test "writes stop with the abandoned requests when it shuts down", %{tmp_dir: dir} do
    {writer, set_clock} = start_writer(dir, "2026-10-23T21:00:00.000000+09:00")

    Writer.start(writer, {192, 0, 2, 1})
    Writer.abandoned(writer, 1)
    Writer.abandoned(writer, 0)
    Writer.abandoned(writer, 2)
    set_clock.("2026-10-23T21:05:00.000000+09:00")
    stop_supervised!(Writer)

    assert [_, stop] =
             Writer.path(dir, "core1", "2026-10-23")
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&:json.decode/1)

    assert stop == %{
             "v" => 1,
             "ts" => "2026-10-23T21:05:00.000000+09:00",
             "target" => "core1",
             "event" => "stop",
             "abandoned" => 3
           }
  end
end
