defmodule Detchi.ClockTest do
  use ExUnit.Case, async: true

  alias Detchi.Clock

  # 2026-10-27T10:00:00Z
  @now 1_793_095_200_000_000
  @interval_ms 10

  setup %{test: test} do
    registry = :"#{test}"
    start_supervised!({Detchi.Registry, name: registry})
    %{registry: registry}
  end

  # A Writer that passes the casts it gets on to the test.
  defp start_writer(registry, target) do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, _} = Registry.register(registry, {:writer, target}, nil)
        send(test, {:registered, target})
        forward(test, target)
      end)

    assert_receive {:registered, ^target}
    pid
  end

  defp forward(test, target) do
    receive do
      {:"$gen_cast", msg} -> send(test, {target, msg})
    end

    forward(test, target)
  end

  # The wall clock of the Clock, moved by the test; the monotonic clock
  # stands still.
  defp start_clock(registry) do
    wall = :atomics.new(1, signed: true)
    :atomics.put(wall, 1, @now)

    start_supervised!(
      {Clock,
       name: nil,
       registry: registry,
       clock: fn -> :atomics.get(wall, 1) end,
       monotonic: fn -> 0 end,
       interval_ms: @interval_ms}
    )

    fn step_us -> :atomics.add(wall, 1, step_us) end
  end

  # Long enough for a few checks.
  @wait_ms 20 * @interval_ms

  test "a step forward is written by every Writer", %{registry: registry} do
    start_writer(registry, "core1")
    start_writer(registry, "sw1")
    step = start_clock(registry)

    step.(5_000_000)

    assert_receive {"core1", {:event, :clock_stepped, %{offset_us: 5_000_000}}}, @wait_ms
    assert_receive {"sw1", {:event, :clock_stepped, %{offset_us: 5_000_000}}}, @wait_ms
    refute_receive {_, _}, @wait_ms
  end

  test "a step back is negative", %{registry: registry} do
    start_writer(registry, "core1")
    step = start_clock(registry)

    step.(-5_000_000)

    assert_receive {"core1", {:event, :clock_stepped, %{offset_us: -5_000_000}}}, @wait_ms
  end

  test "a step of exactly the threshold is written", %{registry: registry} do
    start_writer(registry, "core1")
    step = start_clock(registry)

    step.(-1_000_000)

    assert_receive {"core1", {:event, :clock_stepped, %{offset_us: -1_000_000}}}, @wait_ms
  end

  test "smaller changes are not written, and do not add up", %{registry: registry} do
    start_writer(registry, "core1")
    step = start_clock(registry)

    step.(999_999)
    refute_receive {_, _}, @wait_ms
    step.(999_999)
    refute_receive {_, _}, @wait_ms

    # Compared with the check before, not with the first.
    step.(3_000_000)
    assert_receive {"core1", {:event, :clock_stepped, %{offset_us: 3_000_000}}}, @wait_ms
  end

  test "without Writers, a step is let go", %{registry: registry} do
    step = start_clock(registry)
    step.(5_000_000)
    Process.sleep(@wait_ms)

    # The next step is measured from the one before.
    start_writer(registry, "core1")
    step.(2_000_000)
    assert_receive {"core1", {:event, :clock_stepped, %{offset_us: 2_000_000}}}, @wait_ms
  end
end
