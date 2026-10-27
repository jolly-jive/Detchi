defmodule Detchi.CLI.Status do
  @moduledoc """
  `detchi status`: tells from the records whether Detchi is recording
  (docs/basic-design.md, 9.5). It reads the config and `<data_dir>`, and
  writes nothing.

  For each target in the config, the time it was last written is the
  largest mtime of the files of the two latest dates. A target is
  `stale` when that is longer ago than its limit,
  `max(2 * shortest interval + longest timeout, 30s)`, or when it has
  never been written. An mtime in the future counts as now.

  One line for each target goes to stdout; with `quiet: true`, only
  those that are `stale`. Errors and warnings of the config, and
  directories that cannot be read, go to stderr.

  Exits with 0 when every target is `ok`, and with 1 when one is
  `stale`, or when it cannot be told (an error in the config, a
  directory that cannot be read).
  """

  alias Detchi.{CLI, Config, RecordFiles}
  alias Detchi.Config.Target

  @min_limit_ms 30_000
  # Times to list a directory again when a file goes away before its
  # mtime is read (the Housekeeper compressed it).
  @attempts 3

  @type option ::
          {:quiet, boolean()}
          | {:now, integer()}
          | {:offset, charlist()}

  @doc """
  Runs the command and returns the exit status.

  Options:

    * `:quiet`: print only the `stale` targets.
    * `:now`: the wall clock in seconds. For tests.
    * `:offset`: the UTC offset of the times printed, as
      `:calendar.system_time_to_rfc3339/2` takes it. Defaults to the
      local time. For tests.
  """
  @spec run([option()]) :: 0 | 1
  def run(opts \\ []) do
    path = Config.path()

    case Config.load(path) do
      {:ok, config, warnings} ->
        CLI.print_issues(warnings, path, :stderr)
        report(config, opts)

      {:error, errors} ->
        CLI.print_issues(errors, path, :stderr)
        IO.puts(:stderr, "#{path}: #{CLI.count(errors, "error")}")
        1
    end
  end

  defp report(config, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    rows =
      for target <- config.targets do
        {target.name, limit_s(target), last_written(config.data_dir, target.name)}
      end

    name_width = rows |> Enum.map(fn {name, _, _} -> String.length(name) end) |> Enum.max()

    age_width =
      rows
      |> Enum.map(fn
        {_, _, {:ok, mtime}} when is_integer(mtime) -> String.length(age_text(now, mtime))
        _ -> 0
      end)
      |> Enum.max()

    results =
      for {name, limit, result} <- rows do
        case result do
          {:ok, mtime} ->
            verdict = verdict(now, mtime, limit)

            if verdict == "stale" or not Keyword.get(opts, :quiet, false) do
              IO.puts(line(verdict, name, now, mtime, limit, name_width, age_width, opts))
            end

            verdict

          {:error, message} ->
            IO.puts(:stderr, message)
            :error
        end
      end

    if Enum.all?(results, &(&1 == "ok")), do: 0, else: 1
  end

  @doc """
  The limit of a target in seconds, rounded up:
  `max(2 * shortest interval + longest timeout, 30s)`.
  """
  @spec limit_s(Target.t()) :: pos_integer()
  def limit_s(%Target{probes: probes}) do
    interval = probes |> Enum.map(& &1.interval_ms) |> Enum.min()
    timeout = probes |> Enum.map(& &1.timeout_ms) |> Enum.max()
    ms = max(2 * interval + timeout, @min_limit_ms)
    div(ms + 999, 1000)
  end

  @doc """
  The time a target was last written, in seconds: the largest mtime of
  its files of the two latest dates, or `nil` if it has none (or no
  directory).
  """
  @spec last_written(Path.t(), String.t()) ::
          {:ok, integer() | nil} | {:error, String.t()}
  def last_written(data_dir, target), do: last_written(data_dir, target, @attempts)

  defp last_written(data_dir, target, attempts) do
    dir = Path.join(data_dir, target)

    with {:ok, names} <- ls(dir) do
      files =
        for name <- names, {date, _, false} <- [RecordFiles.parse(target, name)], do: {date, name}

      dates = files |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort(:desc) |> Enum.take(2)
      paths = for {date, name} <- files, date in dates, do: Path.join(dir, name)

      case mtimes(paths) do
        {:ok, []} -> {:ok, nil}
        {:ok, mtimes} -> {:ok, Enum.max(mtimes)}
        :gone when attempts > 1 -> last_written(data_dir, target, attempts - 1)
        :gone -> {:error, "#{dir}: error: the files changed while being read"}
        {:error, path, errno} -> {:error, "#{path}: error: cannot read the file (#{errno})"}
      end
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, names}
      {:error, :enoent} -> {:ok, []}
      {:error, errno} -> {:error, "#{dir}: error: cannot read the directory (#{errno})"}
    end
  end

  defp mtimes(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{mtime: mtime}} -> {:cont, {:ok, [mtime | acc]}}
        {:error, :enoent} -> {:halt, :gone}
        {:error, errno} -> {:halt, {:error, path, errno}}
      end
    end)
  end

  defp verdict(_now, nil, _limit), do: "stale"
  defp verdict(now, mtime, limit), do: if(age(now, mtime) > limit, do: "stale", else: "ok")

  # A wall clock stepped back can put the mtime in the future.
  defp age(now, mtime), do: max(now - mtime, 0)

  defp age_text(now, mtime), do: "age #{age(now, mtime)}s"

  defp line(verdict, name, now, mtime, limit, name_width, age_width, opts) do
    middle =
      if mtime do
        last = :calendar.system_time_to_rfc3339(mtime, offset: Keyword.get(opts, :offset, ~c""))
        "last #{last}  " <> String.pad_trailing(age_text(now, mtime), age_width)
      else
        # As wide as the line of a time: "last " and RFC 3339 to seconds
        # with an offset are 30 characters.
        String.pad_trailing("never written", 30 + 2 + age_width)
      end

    String.pad_trailing(verdict, 5) <>
      "  " <> String.pad_trailing(name, name_width) <> "  " <> middle <> "  limit #{limit}s"
  end
end
