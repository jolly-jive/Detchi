defmodule Detchi.Housekeeper do
  @moduledoc """
  Compresses the record files of past dates and deletes those past the
  retention (docs/basic-design.md, 3.1, 6.2, 6.4). One for the system,
  so that compressions do not overlap on a Raspberry Pi.

  The work comes in order and is done one at a time:

    * `file_closed/2`: a Writer closed the file of a past date.
    * `compress_before/3`: a Writer started; the files of its target
      before the date it started are no longer written. This picks up
      files left when a Writer or the Housekeeper went down.
    * A sweep of `<data_dir>`, at start and then every 24 hours by the
      monotonic clock: leftover `.part` files are deleted, files past the
      retention are deleted, `.jsonl` files before yesterday (before
      today, for targets not in the config) are compressed, and empty
      directories of targets not in the config are removed.

  Only files that match the naming rule exactly are touched.

  A file is compressed into `<name>.part`, synced, given the mtime of
  the `.jsonl`, renamed, and then the directory is synced before the
  `.jsonl` is deleted. If the compressed file is there already (Detchi
  stopped before the delete), it is made again from the `.jsonl`.
  """

  use GenServer

  require Logger

  alias Detchi.Config
  alias Detchi.{Record, RecordFiles}

  @sweep_interval_ms 24 * 60 * 60 * 1000
  @chunk_size 64 * 1024

  @type option ::
          {:config, Config.t()}
          | {:name, GenServer.name()}
          | {:clock, (-> integer())}
          | {:offset, charlist()}
          | {:sweep_interval_ms, pos_integer()}

  @doc """
  Starts the Housekeeper.

  Options:

    * `:config` (required): the validated config, for `data_dir`,
      `retention_days`, `compression` and the names of the targets.
    * `:name`: defaults to `Detchi.Housekeeper`.
    * `:clock`: the wall clock in microseconds. For tests.
    * `:offset`: the UTC offset of the local dates, as
      `:calendar.system_time_to_rfc3339/2` takes it. Defaults to the
      local time. For tests.
    * `:sweep_interval_ms`: defaults to 24 hours. For tests.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Asks to compress a `.jsonl` file a Writer has closed."
  @spec file_closed(GenServer.server(), Path.t()) :: :ok
  def file_closed(housekeeper, path), do: GenServer.cast(housekeeper, {:file_closed, path})

  @doc """
  Asks to compress the `.jsonl` files of a target dated before `date`
  (`YYYY-MM-DD`).
  """
  @spec compress_before(GenServer.server(), String.t(), String.t()) :: :ok
  def compress_before(housekeeper, target, date),
    do: GenServer.cast(housekeeper, {:compress_before, target, date})

  @impl true
  def init(opts) do
    %Config{} = config = Keyword.fetch!(opts, :config)

    # RTTs are timed inside the BEAM; compression must not delay them.
    Process.flag(:priority, :low)

    state = %{
      data_dir: config.data_dir,
      retention_days: config.retention_days,
      compression: config.compression,
      targets: MapSet.new(config.targets, & &1.name),
      clock: Keyword.get(opts, :clock, fn -> System.os_time(:microsecond) end),
      offset: Keyword.get(opts, :offset, ~c""),
      sweep_interval_ms: Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    }

    {:ok, state, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    sweep(state)
    Process.send_after(self(), :sweep, state.sweep_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:file_closed, path}, state) do
    compress(state, path)
    {:noreply, state}
  end

  def handle_cast({:compress_before, target, date}, state) do
    for {file_date, path} <- jsonl_files(state, target),
        file_date < date,
        do: compress(state, path)

    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state), do: {:noreply, state, {:continue, :sweep}}

  defp sweep(state) do
    today = today(state)
    yesterday = today |> Date.add(-1) |> to_string()
    cutoff = today |> Date.add(-state.retention_days) |> to_string()
    today = to_string(today)

    for target <- targets(state) do
      configured? = MapSet.member?(state.targets, target)
      compress_before = if configured?, do: yesterday, else: today

      for {date, ext, part?, path} <- files(state, target) do
        cond do
          part? -> delete(path)
          date < cutoff -> delete(path)
          ext == nil and date < compress_before -> compress(state, path)
          true -> :ok
        end
      end

      # A Writer makes its directory before opening a file in it; the
      # directories of the targets in the config stay.
      if not configured?, do: File.rmdir(Path.join(state.data_dir, target))
    end
  end

  defp targets(state) do
    case File.ls(state.data_dir) do
      {:ok, names} ->
        Enum.filter(
          names,
          &(RecordFiles.target_name?(&1) and File.dir?(Path.join(state.data_dir, &1)))
        )

      {:error, :enoent} ->
        []

      {:error, errno} ->
        Logger.error("cannot list #{state.data_dir} (#{errno})")
        []
    end
  end

  # The files of a target that match the naming rule exactly, as
  # {date, nil | "gz" | "zst", part?, path}.
  defp files(state, target) do
    dir = Path.join(state.data_dir, target)

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names, {date, ext, part?} <- [RecordFiles.parse(target, name)] do
          {date, ext, part?, Path.join(dir, name)}
        end

      {:error, :enoent} ->
        []

      {:error, errno} ->
        Logger.error("cannot list #{dir} (#{errno})")
        []
    end
  end

  defp jsonl_files(state, target),
    do: for({date, nil, false, path} <- files(state, target), do: {date, path})

  defp delete(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, errno} -> Logger.error("cannot delete #{path} (#{errno})")
    end
  end

  defp compress(state, path) do
    case File.stat(path, time: :posix) do
      {:ok, info} ->
        compress(state, path, info.mtime)

      # Done already: asked twice, by a Writer and by a sweep.
      {:error, :enoent} ->
        :ok

      {:error, errno} ->
        Logger.error("cannot compress #{path} (#{errno}); left for later")
    end
  end

  # Files are 0644 whatever the umask is, as the Writer makes them.
  defp compress(state, path, mtime) do
    out = path <> extension(state.compression)
    part = out <> ".part"

    with :ok <- write_compressed(state.compression, path, part),
         :ok <- :file.change_mode(part, 0o644),
         :ok <- File.touch(part, mtime),
         :ok <- File.rename(part, out),
         :ok <- sync_dir(Path.dirname(path)),
         :ok <- File.rm(path) do
      :ok
    else
      {:error, errno} ->
        File.rm(part)
        Logger.error("cannot compress #{path} (#{errno}); left for later")
    end
  end

  defp extension(:gzip), do: ".gz"
  defp extension(:zstd), do: ".zst"

  defp write_compressed(compression, path, part) do
    with {:ok, input} <- :file.open(path, [:read, :raw, :binary]) do
      try do
        with {:ok, output} <- :file.open(part, [:write, :raw, :binary]) do
          try do
            with :ok <- copy(compression, input, output), do: :file.sync(output)
          after
            :file.close(output)
          end
        end
      after
        :file.close(input)
      end
    end
  end

  defp copy(:gzip, input, output) do
    z = :zlib.open()

    try do
      # 16 + 15 window bits: the gzip format.
      :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)
      pump(input, output, &:zlib.deflate(z, &1), fn -> :zlib.deflate(z, [], :finish) end)
    after
      :zlib.close(z)
    end
  end

  defp copy(:zstd, input, output) do
    {:ok, ctx} = :zstd.context(:compress)

    pump(
      input,
      output,
      fn data -> with {:continue, out} <- :zstd.stream(ctx, data), do: out end,
      fn -> with {:done, out} <- :zstd.finish(ctx, <<>>), do: out end
    )
  end

  defp pump(input, output, compress, finish) do
    case :file.read(input, @chunk_size) do
      {:ok, data} ->
        with :ok <- :file.write(output, compress.(data)),
             do: pump(input, output, compress, finish)

      :eof ->
        :file.write(output, finish.())

      error ->
        error
    end
  end

  # Makes the rename durable before the `.jsonl` goes.
  defp sync_dir(dir) do
    with {:ok, fd} <- :file.open(dir, [:read, :raw, :directory]) do
      try do
        :file.sync(fd)
      after
        :file.close(fd)
      end
    end
  end

  defp today(state) do
    state.clock.()
    |> Record.format_ts(offset: state.offset)
    |> binary_part(0, 10)
    |> Date.from_iso8601!()
  end
end
