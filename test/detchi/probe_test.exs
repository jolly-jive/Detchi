defmodule Detchi.ProbeTest do
  use ExUnit.Case, async: true

  alias Detchi.Config.Probe, as: ProbeConfig
  alias Detchi.{Addresses, Probe}

  @moduletag :capture_log

  @addr {192, 0, 2, 1}

  # Stands for the Writer: passes the lines and the abandoned counts on
  # to the test.
  defmodule FakeWriter do
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test)

    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_cast({:write, record}, test) do
      send(test, {:line, record})
      {:noreply, test}
    end

    @impl true
    def handle_call({:abandoned, count}, _from, test) do
      send(test, {:abandoned, count})
      {:reply, :ok, test}
    end
  end

  setup %{test: test} do
    table = Addresses.create(:"#{test}")
    {:ok, writer} = FakeWriter.start_link(self())
    %{table: table, writer: writer}
  end

  defp start_probe(ctx, measure, probe \\ []) do
    probe =
      struct!(
        %ProbeConfig{name: "ping", protocol: :icmp, interval_ms: 100, timeout_ms: 50},
        probe
      )

    start_supervised!(
      {Probe,
       target: "core1", probe: probe, writer: ctx.writer, table: ctx.table, measure: measure}
    )
  end

  # Tells the test about each attempt, and returns `result`.
  defp answering(result) do
    test = self()

    fn addr, probe ->
      send(test, {:attempt, addr, probe.name, System.os_time(:millisecond)})
      Map.put(result, :ts, System.os_time(:microsecond))
    end
  end

  describe "times" do
    test "first_delay/3 waits for the next multiple of the interval plus the phase" do
      assert Probe.first_delay(120_000, 60_000, 0) == 0
      assert Probe.first_delay(120_001, 60_000, 0) == 59_999
      assert Probe.first_delay(120_000, 60_000, 1_500) == 1_500
      assert Probe.first_delay(121_500, 60_000, 1_500) == 0
      assert Probe.first_delay(122_000, 60_000, 1_500) == 59_500
    end

    test "next_due/3 adds the interval, and skips the times that have passed" do
      assert Probe.next_due(1_000, 1_000, 100) == 1_100
      assert Probe.next_due(1_000, 1_099, 100) == 1_100
      assert Probe.next_due(1_000, 1_100, 100) == 1_200
      assert Probe.next_due(1_000, 1_350, 100) == 1_400
      # A timer may fire a little early on the monotonic clock.
      assert Probe.next_due(1_000, 999, 100) == 1_100
    end

    test "phase/3 is within the interval and depends on the names" do
      phases =
        for target <- ~w(core1 sw1 sw2), probe <- ~w(ping ssh dns) do
          phase = Probe.phase(target, probe, 60_000)
          assert phase in 0..59_999
          assert phase == Probe.phase(target, probe, 60_000)
          phase
        end

      assert length(Enum.uniq(phases)) == 9
    end
  end

  test "attempts at the phase on the wall clock, in steps of the interval", ctx do
    start_probe(ctx, answering(%{status: :ok, rtt_us: 10}), interval_ms: 1_000, timeout_ms: 500)
    Addresses.put(ctx.table, "core1", @addr)
    phase = Probe.phase("core1", "ping", 1_000)

    times =
      for _ <- 1..3 do
        assert_receive {:attempt, @addr, "ping", t}, 2_000
        t
      end

    # Off the phase in either direction: the clocks are read in whole
    # milliseconds, and a busy test run can make an attempt late. A late
    # attempt does not move the ones after it.
    off = Enum.map(times, &abs(Integer.mod(&1 - phase + 500, 1_000) - 500))
    assert Enum.count(off, &(&1 < 50)) >= 2, "off the phase by #{inspect(off)} ms"
  end

  test "writes the line of an attempt, with the fields of the probe", ctx do
    Addresses.put(ctx.table, "core1", @addr)
    start_probe(ctx, answering(%{status: :ok, rtt_us: 10}))

    assert_receive {:line, record}, 500

    assert %{probe: "ping", protocol: :icmp, addr: @addr, status: :ok, rtt_us: 10, ts: ts} =
             record

    assert is_integer(ts)
  end

  test "does not measure a target that has not written start", ctx do
    start_probe(ctx, answering(%{status: :ok, rtt_us: 10}))
    refute_receive {:attempt, _, _, _}, 300

    Addresses.put(ctx.table, "core1", @addr)
    assert_receive {:attempt, @addr, _, _}, 300
  end

  test "writes the error of a host name that has never resolved, without an address", ctx do
    Addresses.put(ctx.table, "core1", {:unresolved, :nxdomain})
    start_probe(ctx, answering(%{status: :ok, rtt_us: 10}))

    assert_receive {:line, record}, 500
    assert %{probe: "ping", status: :error, error: {:resolve, :nxdomain}, addr: nil} = record
    refute_received {:attempt, _, _, _}
  end

  test "an Attempt that fails is written as internal, and the Probe goes on", ctx do
    Addresses.put(ctx.table, "core1", @addr)
    pid = start_probe(ctx, fn _, _ -> raise "boom" end)

    assert_receive {:line, %{status: :error, error: :internal, addr: @addr, ts: _}}, 500
    assert_receive {:line, %{status: :error, error: :internal}}, 500
    assert Process.alive?(pid)
  end

  test "an Attempt that is stuck is cut off and written as internal; the times in between are skipped",
       ctx do
    test = self()
    Addresses.put(ctx.table, "core1", @addr)

    pid =
      start_probe(ctx, fn _, _ ->
        send(test, {:stuck, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:stuck, attempt}, 500
    ref = Process.monitor(attempt)
    # The timeout (50ms) and the margin (1s).
    refute_receive {:line, _}, 900
    assert_receive {:line, %{status: :error, error: :internal}}, 500
    assert_receive {:DOWN, ^ref, _, _, :killed}
    refute_received {:stuck, _}
    assert Process.alive?(pid)
  end

  test "on shutdown, an Attempt still waiting is cut off and counted", ctx do
    test = self()
    Addresses.put(ctx.table, "core1", @addr)

    start_probe(ctx, fn _, _ ->
      send(test, {:stuck, self()})
      Process.sleep(:infinity)
    end)

    assert_receive {:stuck, attempt}, 500
    ref = Process.monitor(attempt)
    :ok = stop_supervised({Probe, "ping"})

    assert_received {:abandoned, 1}
    assert_receive {:DOWN, ^ref, _, _, _}
    refute_received {:line, _}
  end

  test "on shutdown without an Attempt, nothing is counted", ctx do
    start_probe(ctx, answering(%{status: :ok, rtt_us: 10}))
    :ok = stop_supervised({Probe, "ping"})
    refute_received {:abandoned, _}
  end
end
