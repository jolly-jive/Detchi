defmodule Detchi.Probe do
  @moduledoc """
  Runs one probe of a target (docs/basic-design.md, 3.1, 7.5).

  The Probe keeps the times of the probe and does not wait itself: each
  attempt runs in a Task (the Attempt), which sends, waits and returns
  the fields of the measurement line. The Probe adds the rest and hands
  the line to the Writer.

  The first attempt is at a time on the wall clock that is a multiple of
  `interval` plus a phase taken from the names of the target and the
  probe, so that a probe is measured at the same times after a restart.
  From there the times go on the monotonic clock. A time that has passed
  while the Probe was late is skipped.

  The address is read from the address table on each attempt. A target
  without a row has not written `start` yet, and is not measured; one
  whose host name has never resolved gets a line with the error.

  An Attempt that fails, or runs `timeout` and a margin, is written as
  `internal`. On shutdown, an Attempt still waiting is cut off and
  counted in the `stop` line of the Writer.
  """

  use GenServer

  require Logger

  alias Detchi.{Addresses, Writer}
  alias Detchi.Config.Probe, as: ProbeConfig

  # Added to the timeout of the probe before an Attempt is cut off. The
  # Attempt keeps the timeout itself; this is for one that is stuck.
  @overdue_margin_ms 1_000

  @type measure :: (:inet.ip_address(), ProbeConfig.t() -> map())

  @type option ::
          {:target, String.t()}
          | {:probe, ProbeConfig.t()}
          | {:writer, GenServer.server()}
          | {:table, atom()}
          | {:snmp, Detchi.Config.Target.snmp() | nil}
          | {:measure, measure()}

  @doc """
  Starts a Probe.

  Options:

    * `:target` (required): the name of the target.
    * `:probe` (required): the probe, as in the config.
    * `:writer` (required): the Writer of the target.
    * `:table`: the address table. Defaults to `Detchi.Addresses`.
    * `:snmp`: the `snmp` of the target, for an SNMP probe.
    * `:measure`: runs one attempt, as `Detchi.Icmp.measure/2`. Defaults
      to the one of the protocol. For tests.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def child_spec(opts) do
    %ProbeConfig{name: name} = Keyword.fetch!(opts, :probe)
    %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  The phase of a probe in milliseconds, from 0 to `interval_ms - 1`.
  `:erlang.phash2/2` gives the same value on any machine and ERTS version.
  """
  @spec phase(String.t(), String.t(), pos_integer()) :: non_neg_integer()
  def phase(target, probe, interval_ms), do: :erlang.phash2({target, probe}, interval_ms)

  @doc """
  The time from `now` (system time in milliseconds) to the first attempt:
  the next time that is a multiple of `interval_ms` plus `phase_ms`, or
  `now` itself.
  """
  @spec first_delay(integer(), pos_integer(), non_neg_integer()) :: non_neg_integer()
  def first_delay(now, interval_ms, phase_ms), do: Integer.mod(phase_ms - now, interval_ms)

  @doc """
  The time of the attempt after the one due at `due`, when it is run at
  `now` (both monotonic): `due + interval_ms`, or, if that has passed,
  the first time after `now` in steps of `interval_ms` from `due`.
  """
  @spec next_due(integer(), integer(), pos_integer()) :: integer()
  def next_due(due, now, interval_ms),
    do: due + interval_ms * (max(div(now - due, interval_ms), 0) + 1)

  @impl true
  def init(opts) do
    # Trapping exits makes terminate/2 run on shutdown, to count the
    # Attempt that is cut off.
    Process.flag(:trap_exit, true)

    %ProbeConfig{} = probe = Keyword.fetch!(opts, :probe)
    target = Keyword.fetch!(opts, :target)
    snmp = Keyword.get(opts, :snmp)

    state = %{
      target: target,
      probe: probe,
      writer: Keyword.fetch!(opts, :writer),
      table: Keyword.get(opts, :table, Addresses),
      snmp: snmp,
      measure: Keyword.get_lazy(opts, :measure, fn -> measure(probe, target, snmp) end),
      due: nil,
      # nil, or %{task: Task.t(), addr: address, ts: system time, timer: ref}.
      attempt: nil
    }

    delay =
      first_delay(
        System.os_time(:millisecond),
        probe.interval_ms,
        phase(target, probe.name, probe.interval_ms)
      )

    {:ok, schedule(state, System.monotonic_time(:millisecond) + delay)}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    state = schedule(state, next_due(state.due, now, state.probe.interval_ms))
    {:noreply, attempt(state)}
  end

  def handle_info({ref, result}, %{attempt: %{task: %Task{ref: ref}} = attempt} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, attempt, {:ok, result})}
  end

  def handle_info(
        {:DOWN, ref, _, _, reason},
        %{attempt: %{task: %Task{ref: ref}} = attempt} = state
      ),
      do: {:noreply, finish(state, attempt, {:exit, reason})}

  def handle_info({:overdue, ref}, %{attempt: %{task: %Task{ref: ref}} = attempt} = state),
    do: {:noreply, finish(state, attempt, Task.shutdown(attempt.task, :brutal_kill) || :overdue)}

  # The exit of an Attempt comes with its :DOWN; an :overdue may come
  # after the Attempt has finished.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:overdue, _ref}, state), do: {:noreply, state}

  # Supervisors stop the Probe with :shutdown; SIGTERM comes this way.
  # An Attempt that has finished but not been taken is still written.
  @impl true
  def terminate(reason, %{attempt: %{} = attempt} = state) do
    case Task.shutdown(attempt.task, :brutal_kill) do
      {:ok, result} ->
        write(state, attempt.addr, result)

      _ ->
        if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
          do: abandoned(state)
    end
  end

  def terminate(_reason, _state), do: :ok

  defp measure(%ProbeConfig{protocol: :icmp}, _, _), do: &Detchi.Icmp.measure/2
  defp measure(%ProbeConfig{protocol: :tcp}, _, _), do: &Detchi.Tcp.measure/2
  defp measure(%ProbeConfig{protocol: :udp}, _, _), do: &Detchi.Udp.measure/2

  # snmpm sends to the address the target is registered at, and the
  # line tells which (Detchi.Snmp.measure/3).
  defp measure(%ProbeConfig{protocol: :snmp}, target, %{credential: %{version: version}}),
    do: fn _addr, probe -> Detchi.Snmp.measure(target, version, probe) end

  defp schedule(state, due) do
    Process.send_after(self(), :tick, due, abs: true)
    %{state | due: due}
  end

  # The previous Attempt is still waiting only if it is late; the time is
  # skipped then.
  defp attempt(%{attempt: %{}} = state), do: state

  defp attempt(state) do
    case Addresses.lookup(state.table, state.target) do
      nil ->
        state

      {:unresolved, errno} ->
        write(state, nil, %{
          ts: System.os_time(:microsecond),
          status: :error,
          error: {:resolve, errno}
        })

        state

      addr ->
        %{measure: measure, probe: probe} = state
        task = Task.async(fn -> measure.(addr, probe) end)

        timer =
          Process.send_after(self(), {:overdue, task.ref}, probe.timeout_ms + @overdue_margin_ms)

        %{
          state
          | attempt: %{task: task, addr: addr, ts: System.os_time(:microsecond), timer: timer}
        }
    end
  end

  defp finish(state, attempt, outcome) do
    Process.cancel_timer(attempt.timer)

    case outcome do
      {:ok, result} ->
        write(state, attempt.addr, result)

      failure ->
        # Exit reasons of Attempts must not hold credentials (docs/basic-design.md, 6.1).
        Logger.error("#{state.target}/#{state.probe.name}: attempt failed: #{describe(failure)}")
        write(state, attempt.addr, %{ts: attempt.ts, status: :error, error: :internal})
    end

    %{state | attempt: nil}
  end

  defp describe(:overdue), do: "no result within the timeout and #{@overdue_margin_ms}ms"
  defp describe({:exit, reason}), do: Exception.format_exit(reason)

  defp write(state, addr, result) do
    %ProbeConfig{} = probe = state.probe

    record =
      Map.merge(
        %{
          probe: probe.name,
          protocol: probe.protocol,
          addr: addr,
          port: probe.port,
          udp: probe.service && %{service: probe.service}
        },
        protocol_fields(probe, state.snmp)
      )
      |> Map.merge(result)

    Writer.write(state.writer, record)
  end

  # An SNMP line without a result from snmpm still tells the port and
  # what was asked.
  defp protocol_fields(%ProbeConfig{protocol: :snmp}, %{credential: credential, port: port}),
    do: %{port: port, snmp: %{version: credential.version, op: :get}}

  defp protocol_fields(_probe, _snmp), do: %{}

  # The Writer may have gone first, when it fails and takes the Probes
  # down with it.
  defp abandoned(state) do
    Writer.abandoned(state.writer, 1)
  catch
    :exit, _ -> :ok
  end
end
