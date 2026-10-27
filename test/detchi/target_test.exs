defmodule Detchi.TargetTest do
  use ExUnit.Case, async: true

  alias Detchi.Config.{Probe, Target}
  alias Detchi.{Addresses, Writer}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @target %Target{
    name: "core1",
    host: "192.0.2.1",
    address: {192, 0, 2, 1},
    family: :auto,
    probes: [%Probe{name: "ping", protocol: :icmp, interval_ms: 60_000, timeout_ms: 1000}]
  }

  @now "2026-10-23T21:00:00+09:00"

  setup %{tmp_dir: dir, test: test} do
    registry = :"#{test}.registry"
    start_supervised!({Detchi.Registry, name: registry})
    table = Addresses.create(:"#{test}.addresses")
    clock = :calendar.rfc3339_to_system_time(String.to_charlist(@now), unit: :microsecond)

    sup =
      start_supervised!(
        {Detchi.Target,
         target: @target,
         data_dir: dir,
         resolve_interval_ms: 3_600_000,
         registry: registry,
         table: table,
         writer_opts: [housekeeper: self(), clock: fn -> clock end, offset: ~c"+09:00"]}
      )

    %{dir: dir, registry: registry, table: table, sup: sup}
  end

  defp writer(ctx), do: Detchi.Registry.writer(ctx.registry, "core1")

  defp resolver(ctx) do
    [{Detchi.Resolver, pid, _, _}] =
      Supervisor.which_children(ctx.sup) |> Enum.filter(&match?({Detchi.Resolver, _, _, _}, &1))

    pid
  end

  # Waits until the Resolver has handed `start` to the Writer.
  defp settle(ctx), do: :sys.get_state(resolver(ctx))

  defp events(ctx) do
    :sys.get_state(writer(ctx))

    Writer.path(ctx.dir, "core1", "2026-10-23")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> :json.decode() |> Map.get("event")))
  end

  test "the Writer is registered and the Resolver writes start through it", ctx do
    settle(ctx)
    assert [{"core1", _}] = Detchi.Registry.writers(ctx.registry)
    assert events(ctx) == ["start"]
    assert Addresses.lookup(ctx.table, "core1") == {192, 0, 2, 1}
  end

  test "a restarted Writer is registered again, and start is written again", ctx do
    settle(ctx)
    [{"core1", old}] = Detchi.Registry.writers(ctx.registry)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}

    settle(ctx)
    assert [{"core1", new}] = Detchi.Registry.writers(ctx.registry)
    assert new != old
    assert events(ctx) == ["start", "start"]
  end

  # As under Detchi.Supervisor, the test supervisor (one_for_one) starts
  # the registry again.
  test "the Writer stops when the registry goes, and registers again", ctx do
    settle(ctx)
    [{"core1", old}] = Detchi.Registry.writers(ctx.registry)
    ref = Process.monitor(old)
    Process.exit(Process.whereis(ctx.registry), :kill)
    assert_receive {:DOWN, ^ref, _, _, _}

    wait_until(fn -> match?([{"core1", pid}] when pid != old, writers(ctx)) end)
  end

  test "the probes measure through the Writer, and count what they cut off in stop", ctx do
    target = %Target{
      name: "lo",
      host: "127.0.0.1",
      address: {127, 0, 0, 1},
      family: :auto,
      probes: [
        %Probe{name: "ping", protocol: :icmp, interval_ms: 100, timeout_ms: 50},
        %Probe{name: "stuck", protocol: :icmp, interval_ms: 100, timeout_ms: 50}
      ]
    }

    test = self()

    measure = fn
      addr, %Probe{name: "ping"} = probe ->
        Detchi.Icmp.measure(addr, probe)

      _addr, %Probe{name: "stuck"} ->
        send(test, :stuck)
        Process.sleep(:infinity)
    end

    start_supervised!(
      {Detchi.Target,
       target: target,
       data_dir: ctx.dir,
       resolve_interval_ms: 3_600_000,
       registry: ctx.registry,
       table: ctx.table,
       writer_opts: [housekeeper: self()],
       probe_opts: [measure: measure]},
      id: :lo
    )

    assert_receive :stuck, 1_000
    Process.sleep(300)
    :ok = stop_supervised(:lo)

    [path] = Path.wildcard(Path.join([ctx.dir, "lo", "*.jsonl"]))
    lines = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&:json.decode/1)

    assert %{"event" => "start", "addr" => "127.0.0.1"} = hd(lines)
    assert %{"event" => "stop", "abandoned" => 1} = List.last(lines)

    measurements = Enum.filter(lines, & &1["protocol"])
    assert length(measurements) >= 2

    for line <- measurements do
      assert %{"probe" => "ping", "protocol" => "icmp", "addr" => "127.0.0.1", "status" => "ok"} =
               line

      assert is_integer(line["rtt_us"])
    end
  end

  # Empty while the registry is down.
  defp writers(ctx) do
    Detchi.Registry.writers(ctx.registry)
  rescue
    ArgumentError -> []
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end
end
