defmodule Detchi.Writer do
  @moduledoc """
  Writes the record file of one target (docs/basic-design.md, 3.1, 6.2).

  Only the Writer writes to a target's files. Each line goes to the file
  of the local date of its `ts`, `<data_dir>/<target>/<target>-YYYY-MM-DD.jsonl`.
  When the first line of a new date comes, the file of that date is opened
  with a `file_opened` line, and the files of the earlier dates are kept
  open for `grace_ms` more, for results of requests sent before midnight.
  Then they are closed and handed to the Housekeeper, and lines for those
  dates (or for dates before the Writer started) are dropped.

  A line that cannot be written is dropped and counted. When a line can
  be written again, a `dropped` line comes first, with the count and the
  range of `ts` of the dropped lines.

  On shutdown, a `stop` line is written with the number of requests the
  probes cut off (`abandoned/2`). The probes stop before the Writer, as
  the Writer comes first in the target's `rest_for_one` supervisor.
  """

  use GenServer

  require Logger

  alias Detchi.Config.{Fingerprint, Target}
  alias Detchi.{Housekeeper, Record}

  @version Mix.Project.config()[:version]

  # Added to the longest timeout of the target to give the time a file of
  # a past date is kept open.
  @grace_margin_ms 10_000

  @type option ::
          {:target, Target.t()}
          | {:data_dir, Path.t()}
          | {:name, GenServer.name()}
          | {:housekeeper, GenServer.server()}
          | {:grace_ms, non_neg_integer()}
          | {:clock, (-> integer())}
          | {:offset, charlist() | integer()}

  @doc """
  Starts a Writer.

  Options:

    * `:target` (required): the target, as in the config.
    * `:data_dir` (required): the directory of the records.
    * `:name`: the name of the process.
    * `:housekeeper`: the `Detchi.Housekeeper` told when a file of a past
      date is closed, and, at start, asked to compress the files before
      the date the Writer started. Defaults to `Detchi.Housekeeper`.
    * `:grace_ms`: how long files of past dates are kept open. Defaults
      to the longest timeout of the target and a margin.
    * `:clock`: returns the system time in microseconds. For tests.
    * `:offset`: the offset of local time, as `Detchi.Record.encode/2`
      takes it. For tests.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Writes the `start` line, with the address in use (`nil` if the host
  name has not resolved yet), and returns when it is written. The
  Resolver calls this before it puts the first address in the table, so
  that `start` comes before any measurement (docs/basic-design.md, 3.1).
  """
  @spec start(GenServer.server(), :inet.ip_address() | nil) :: :ok
  def start(writer, addr), do: GenServer.call(writer, {:start, addr})

  @doc """
  Writes a measurement line. `record` is a measurement as
  `Detchi.Record.encode/2` takes it, with `ts` and without `target`.
  """
  @spec write(GenServer.server(), map()) :: :ok
  def write(writer, %{ts: _, protocol: _} = record), do: GenServer.cast(writer, {:write, record})

  @doc """
  Writes an event line that others report: `resolve_failed` and
  `addr_changed` from the Resolver, `clock_stepped` from the Clock.
  `ts` is the time the Writer takes it.
  """
  @spec event(GenServer.server(), :resolve_failed | :addr_changed | :clock_stepped, map()) ::
          :ok
  def event(writer, event, fields)
      when event in [:resolve_failed, :addr_changed, :clock_stepped] and is_map(fields),
      do: GenServer.cast(writer, {:event, event, fields})

  @doc """
  Adds to the number of requests cut off without waiting for the result,
  written in the `stop` line. A probe calls this as it stops.
  """
  @spec abandoned(GenServer.server(), non_neg_integer()) :: :ok
  def abandoned(writer, count) when is_integer(count) and count >= 0,
    do: GenServer.call(writer, {:abandoned, count})

  @doc "The path of the record file of a target for a date (`YYYY-MM-DD`)."
  @spec path(Path.t(), String.t(), String.t()) :: Path.t()
  def path(data_dir, target, date), do: Path.join([data_dir, target, "#{target}-#{date}.jsonl"])

  @impl true
  def init(opts) do
    # Trapping exits makes terminate/2 run on shutdown, to write `stop`.
    Process.flag(:trap_exit, true)

    %Target{} = target = Keyword.fetch!(opts, :target)
    clock = Keyword.get(opts, :clock, fn -> System.os_time(:microsecond) end)
    offset = Keyword.get(opts, :offset, ~c"")
    started = clock.() |> date(offset) |> Date.from_iso8601!()

    state = %{
      target: target.name,
      config_hash: Fingerprint.hash(target),
      data_dir: Keyword.fetch!(opts, :data_dir),
      housekeeper: Keyword.get(opts, :housekeeper, Detchi.Housekeeper),
      grace_ms: Keyword.get_lazy(opts, :grace_ms, fn -> default_grace_ms(target) end),
      clock: clock,
      offset: offset,
      addr: nil,
      # Open files by date. Dates are `YYYY-MM-DD`, so they compare as strings.
      files: %{},
      # Lines of this date and earlier are not written: the files are
      # closed, or, before the Writer started, left to the Housekeeper.
      closed_through: started |> Date.add(-1) |> to_string(),
      # nil, or {count, first_ts, last_ts} of the lines not written yet.
      dropped: nil,
      abandoned: 0
    }

    # Files of earlier dates may be left uncompressed, if the Writer before
    # this one went down with them open (docs/basic-design.md, 3.1).
    Housekeeper.compress_before(state.housekeeper, target.name, to_string(started))

    {:ok, state}
  end

  @impl true
  def handle_call({:start, addr}, _from, state) do
    state = %{state | addr: addr, abandoned: 0}
    record = %{event: :start, version: @version, config_hash: state.config_hash, addr: addr}
    {:reply, :ok, put_line(state, now(state), record, false)}
  end

  def handle_call({:abandoned, count}, _from, state),
    do: {:reply, :ok, %{state | abandoned: state.abandoned + count}}

  @impl true
  def handle_cast({:write, record}, state) do
    {ts, record} = Map.pop!(record, :ts)
    {:noreply, put_line(state, ts, record)}
  end

  def handle_cast({:event, event, fields}, state) do
    state =
      case event do
        :addr_changed -> %{state | addr: fields.new}
        _ -> state
      end

    {:noreply, put_line(state, now(state), Map.put(fields, :event, event))}
  end

  @impl true
  def handle_info({:close, through}, state) do
    {closing, files} = Map.split_with(state.files, fn {date, _} -> date <= through end)

    Enum.each(closing, fn {date, fd} ->
      :ok = :file.close(fd)
      Housekeeper.file_closed(state.housekeeper, path(state, date))
    end)

    {:noreply, %{state | files: files, closed_through: max(state.closed_through, through)}}
  end

  # The registry (Detchi.Registry) is linked. If it goes, the entry of the
  # Writer is gone; the Writer stops, to be started again and registered.
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  # Supervisors stop the Writer with :shutdown; SIGTERM comes this way.
  @impl true
  def terminate(reason, state) do
    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
      do: put_line(state, now(state), %{event: :stop, abandoned: state.abandoned})

    Enum.each(state.files, fn {_, fd} -> :file.close(fd) end)
  end

  defp put_line(state, ts, record, file_opened? \\ true) do
    state = flush_dropped(state)

    case append(state, ts, record, file_opened?) do
      {:ok, state} -> state
      {:error, reason, state} -> drop(state, ts, reason)
    end
  end

  defp flush_dropped(%{dropped: nil} = state), do: state

  defp flush_dropped(%{dropped: {count, first_ts, last_ts}} = state) do
    record = %{event: :dropped, count: count, first_ts: first_ts, last_ts: last_ts}

    case append(state, now(state), record, true) do
      {:ok, state} ->
        Logger.info("#{state.target}: writing again; #{count} dropped")
        %{state | dropped: nil}

      {:error, _, state} ->
        state
    end
  end

  defp drop(%{dropped: nil} = state, ts, reason) do
    Logger.error("#{state.target}: dropping lines: #{describe(reason)}")
    %{state | dropped: {1, ts, ts}}
  end

  defp drop(%{dropped: {count, first_ts, last_ts}} = state, ts, _),
    do: %{state | dropped: {count + 1, min(first_ts, ts), max(last_ts, ts)}}

  defp describe({:closed, date}), do: "the file of #{date} is closed"
  defp describe({path, errno}), do: "cannot write #{path} (#{errno})"

  defp append(state, ts, record, file_opened?) do
    date = date(ts, state.offset)

    with :ok <- writable(state, date),
         {:ok, fd, state} <- file(state, date, ts, file_opened?),
         :ok <- write_line(state, fd, date, Map.put(record, :ts, ts)) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp writable(state, date) do
    if date > state.closed_through, do: :ok, else: {:error, {:closed, date}}
  end

  defp file(state, date, ts, file_opened?) do
    case state.files do
      %{^date => fd} ->
        {:ok, fd, state}

      _ ->
        with {:ok, fd} <- open(state, date) do
          schedule_close(state, date)
          state = %{state | files: Map.put(state.files, date, fd)}

          if file_opened? do
            record = %{
              event: :file_opened,
              version: @version,
              config_hash: state.config_hash,
              addr: state.addr,
              # The ts of the line that opened the file, so that it falls
              # on the date of the file.
              ts: ts
            }

            with :ok <- write_line(state, fd, date, record), do: {:ok, fd, state}
          else
            {:ok, fd, state}
          end
        end
    end
  end

  # Files of earlier dates stay open for results of requests sent before
  # midnight. The timer is monotonic, so a step of the wall clock does
  # not move it.
  defp schedule_close(state, date) do
    case state.files |> Map.keys() |> Enum.filter(&(&1 < date)) do
      [] -> :ok
      earlier -> Process.send_after(self(), {:close, Enum.max(earlier)}, state.grace_ms)
    end
  end

  # Directories are 0755 and files 0644 whatever the umask is, so that
  # users of other uids can read them (docs/basic-design.md, 9.2).
  defp open(state, date) do
    dir = Path.join(state.data_dir, state.target)
    path = path(state, date)

    with :ok <- make_dir(dir),
         created? = not File.exists?(path),
         {:ok, fd} <- :file.open(path, [:read, :append, :raw, :binary]),
         :ok <- if(created?, do: :file.change_mode(path, 0o644), else: :ok),
         :ok <- end_with_newline(fd) do
      {:ok, fd}
    else
      {:error, errno} -> {:error, {path, errno}}
    end
  end

  defp make_dir(dir) do
    case File.mkdir(dir) do
      :ok ->
        :file.change_mode(dir, 0o755)

      {:error, :eexist} ->
        :ok

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(Path.dirname(dir)), do: make_dir(dir)

      error ->
        error
    end
  end

  # A file written when Detchi stopped mid-line gets a newline before
  # more lines are appended (docs/basic-design.md, 6.2).
  defp end_with_newline(fd) do
    with {:ok, size} <- :file.position(fd, :eof) do
      case size > 0 and :file.pread(fd, size - 1, 1) do
        false -> :ok
        {:ok, "\n"} -> :ok
        {:ok, _} -> :file.write(fd, "\n")
        error -> error
      end
    end
  end

  defp write_line(state, fd, date, record) do
    line = record |> Map.put(:target, state.target) |> Record.encode(offset: state.offset)

    case :file.write(fd, line) do
      :ok -> :ok
      {:error, errno} -> {:error, {path(state, date), errno}}
    end
  end

  defp path(state, date), do: path(state.data_dir, state.target, date)

  defp now(state), do: state.clock.()

  # The date in the ts of the line, so that the file and its lines agree.
  defp date(ts, offset), do: ts |> Record.format_ts(offset: offset) |> binary_part(0, 10)

  defp default_grace_ms(%Target{probes: probes}),
    do: Enum.max(Enum.map(probes, & &1.timeout_ms)) + @grace_margin_ms
end
