defmodule Detchi.ResolverTest do
  use ExUnit.Case, async: true

  alias Detchi.Config.{Probe, Target}
  alias Detchi.{Addresses, Resolver, Writer}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @target %Target{
    name: "core1",
    host: "core1.example.net",
    family: :auto,
    probes: [%Probe{name: "ping", protocol: :icmp, interval_ms: 60_000, timeout_ms: 1000}]
  }

  @a1 {192, 0, 2, 1}
  @a2 {192, 0, 2, 2}
  @a3 {192, 0, 2, 3}
  @v6 {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

  setup %{tmp_dir: dir, test: test} do
    table = Addresses.create(:"#{test}")

    clock = :calendar.rfc3339_to_system_time(~c"2026-10-23T21:00:00+09:00", unit: :microsecond)

    writer =
      start_supervised!(
        {Writer,
         target: @target,
         data_dir: dir,
         housekeeper: self(),
         clock: fn -> clock end,
         offset: ~c"+09:00"}
      )

    # Answers by family, set by the test; a family without one has no
    # records.
    answers = start_supervised!({Agent, fn -> %{} end})
    %{dir: dir, table: table, writer: writer, answers: answers}
  end

  defp answer(ctx, family, result), do: Agent.update(ctx.answers, &Map.put(&1, family, result))

  defp start_resolver(ctx, opts \\ []) do
    test = self()
    answers = ctx.answers

    lookup = fn host, family, timeout ->
      send(test, {:lookup, host, family, timeout})
      Agent.get(answers, &Map.get(&1, family, {:error, :nxdomain}))
    end

    opts =
      [
        target: @target,
        writer: ctx.writer,
        resolve_interval_ms: 3_600_000,
        first_retry_ms: 3_600_000,
        table: ctx.table,
        lookup: lookup
      ]
      |> Keyword.merge(opts)

    resolver = start_supervised!({Resolver, opts})
    # Waits for the first lookup in handle_continue.
    :sys.get_state(resolver)
    resolver
  end

  defp resolve_again(resolver) do
    send(resolver, :resolve)
    :sys.get_state(resolver)
  end

  # Lines of the file, decoded, without ts; a call makes sure the casts
  # before it are done.
  defp lines(ctx) do
    :sys.get_state(ctx.writer)

    Writer.path(ctx.dir, "core1", "2026-10-23")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(
      &(&1
        |> :json.decode()
        |> Map.drop(["v", "ts", "target", "version", "config_hash"]))
    )
  end

  defp entry(ctx), do: Addresses.lookup(ctx.table, "core1")

  test "does not look up a host that is an IP address", ctx do
    target = %{@target | host: "192.0.2.1", address: @a1}
    start_resolver(ctx, target: target, resolve_interval_ms: 10)

    assert [%{"event" => "start", "addr" => "192.0.2.1"}] = lines(ctx)
    assert entry(ctx) == @a1
    # Not later either.
    refute_receive {:lookup, _, _, _}, 50
  end

  test "writes start with the first address, then puts it in the table", ctx do
    answer(ctx, :inet, {:ok, [@a1, @a2]})
    start_resolver(ctx)

    assert [%{"event" => "start", "addr" => "192.0.2.1"}] = lines(ctx)
    assert entry(ctx) == @a1
    assert_received {:lookup, ~c"core1.example.net", :inet, 5000}
  end

  test "registers an address before it goes to the table", ctx do
    answer(ctx, :inet, {:ok, [@a1]})
    test = self()
    table = ctx.table

    resolver =
      start_resolver(ctx,
        register: &send(test, {:register, &1, Addresses.lookup(table, "core1")})
      )

    assert_received {:register, @a1, nil}

    answer(ctx, :inet, {:ok, [@a2]})
    resolve_again(resolver)
    assert_received {:register, @a2, @a1}
  end

  test "keeps the address while the answer has it, and changes it when not", ctx do
    answer(ctx, :inet, {:ok, [@a1, @a2]})
    resolver = start_resolver(ctx)

    # Round-robin DNS: the address in use comes second now.
    answer(ctx, :inet, {:ok, [@a2, @a1]})
    resolve_again(resolver)
    assert entry(ctx) == @a1

    answer(ctx, :inet, {:ok, [@a3, @a2]})
    resolve_again(resolver)
    assert entry(ctx) == @a3

    assert [_, changed] = lines(ctx)

    assert changed == %{
             "event" => "addr_changed",
             "host" => "core1.example.net",
             "old" => "192.0.2.1",
             "new" => "192.0.2.3"
           }
  end

  test "keeps the address when a lookup fails", ctx do
    answer(ctx, :inet, {:ok, [@a1]})
    resolver = start_resolver(ctx)

    answer(ctx, :inet, {:error, :timeout})
    resolve_again(resolver)

    assert entry(ctx) == @a1
    assert [_, failed] = lines(ctx)

    assert failed == %{
             "event" => "resolve_failed",
             "host" => "core1.example.net",
             "error" => %{"reason" => "resolve", "errno" => "timeout"},
             "addr" => "192.0.2.1"
           }
  end

  test "writes start without an address and resolve_failed when the name never resolved",
       ctx do
    answer(ctx, :inet, {:error, :nxdomain})
    resolver = start_resolver(ctx)

    assert [start, failed] = lines(ctx)
    assert start == %{"event" => "start"}

    assert failed == %{
             "event" => "resolve_failed",
             "host" => "core1.example.net",
             "error" => %{"reason" => "resolve", "errno" => "nxdomain"}
           }

    assert entry(ctx) == {:unresolved, :nxdomain}

    # The table follows the latest reason.
    answer(ctx, :inet, {:error, :timeout})
    resolve_again(resolver)
    assert entry(ctx) == {:unresolved, :timeout}

    answer(ctx, :inet, {:ok, [@a1]})
    resolve_again(resolver)
    assert entry(ctx) == @a1

    assert [_, _, _, changed] = lines(ctx)

    assert changed == %{
             "event" => "addr_changed",
             "host" => "core1.example.net",
             "new" => "192.0.2.1"
           }
  end

  test "auto looks up AAAA only when there is no A", ctx do
    answer(ctx, :inet6, {:ok, [@v6]})
    resolver = start_resolver(ctx)

    assert_received {:lookup, _, :inet, _}
    assert_received {:lookup, _, :inet6, _}
    assert entry(ctx) == @v6

    # A lookup of A that times out is a failure, not a reason to use AAAA.
    answer(ctx, :inet, {:error, :timeout})
    resolve_again(resolver)
    assert_received {:lookup, _, :inet, _}
    refute_received {:lookup, _, :inet6, _}

    # When A comes back, the address goes back to IPv4.
    answer(ctx, :inet, {:ok, [@a1]})
    resolve_again(resolver)
    assert entry(ctx) == @a1
  end

  test "ipv6 and ipv4 look up only their family", ctx do
    answer(ctx, :inet, {:ok, [@a1]})
    answer(ctx, :inet6, {:ok, [@v6]})

    start_resolver(ctx, target: %{@target | family: :ipv6})
    assert entry(ctx) == @v6
    assert_received {:lookup, _, :inet6, _}
    refute_received {:lookup, _, :inet, _}
  end

  test "an unresolved name is retried sooner, doubling up to the interval", ctx do
    start_resolver(ctx, first_retry_ms: 20, resolve_interval_ms: 80)

    times =
      for _ <- 1..5 do
        assert_receive {:lookup, _, :inet, _}, 1000
        assert_receive {:lookup, _, :inet6, _}, 1000
        System.monotonic_time(:millisecond)
      end

    gaps = times |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

    # The first time is that of the first lookup, in handle_continue.
    for {gap, wait} <- Enum.zip(gaps, [20, 40, 80, 80]) do
      assert gap >= wait and gap < wait + 50
    end
  end
end
