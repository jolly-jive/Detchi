defmodule Detchi.Clock do
  @moduledoc """
  Watches for steps of the wall clock, and has every Writer write a
  `clock_stepped` line (docs/basic-design.md, 3.1, 6.1). One for the
  system.

  Every second, the difference between the wall clock and the monotonic
  clock is taken and compared with the one before. If they differ by a
  second or more, the change is written as `offset_us`: positive when the
  wall clock went forward. Comparing with the one before, not the first,
  keeps the slewing of chrony from adding up.

  `erlang:monitor(time_offset, clock_service)` is not used: the time
  offset of the VM follows the wall clock of the OS late, while `ts` is
  taken from the latter.
  """

  use GenServer

  alias Detchi.Writer

  @interval_ms 1000
  @threshold_us 1_000_000

  @type option ::
          {:name, GenServer.name()}
          | {:registry, atom()}
          | {:clock, (-> integer())}
          | {:monotonic, (-> integer())}
          | {:interval_ms, pos_integer()}

  @doc """
  Starts the Clock.

  Options:

    * `:name`: defaults to `Detchi.Clock`.
    * `:registry`: the registry of the Writers. Defaults to
      `Detchi.Registry`.
    * `:clock`: the wall clock in microseconds. For tests.
    * `:monotonic`: the monotonic clock in microseconds. For tests.
    * `:interval_ms`: defaults to a second. For tests.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      registry: Keyword.get(opts, :registry, Detchi.Registry),
      clock: Keyword.get(opts, :clock, fn -> System.os_time(:microsecond) end),
      monotonic: Keyword.get(opts, :monotonic, fn -> System.monotonic_time(:microsecond) end),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      offset: nil
    }

    state = %{state | offset: offset(state)}
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    offset = offset(state)
    step = offset - state.offset

    if abs(step) >= @threshold_us do
      for {_target, writer} <- Detchi.Registry.writers(state.registry),
          do: Writer.event(writer, :clock_stepped, %{offset_us: step})
    end

    schedule(state)
    {:noreply, %{state | offset: offset}}
  end

  defp offset(state), do: state.clock.() - state.monotonic.()

  defp schedule(state), do: Process.send_after(self(), :check, state.interval_ms)
end
