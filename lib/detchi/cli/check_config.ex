defmodule Detchi.CLI.CheckConfig do
  @moduledoc """
  `detchi check-config`: checks the config file without starting
  anything (docs/basic-design.md, 7.9).

  Exits with 0 when the config is valid, warnings or not, and with 1
  when it is not. Errors go to stderr, the rest to stdout.
  """

  alias Detchi.{CLI, Config}

  @spec run() :: 0 | 1
  def run do
    path = Config.path()

    case Config.load(path) do
      {:ok, config, warnings} ->
        CLI.print_issues(warnings, path, :stdio)
        probes = Enum.sum_by(config.targets, &length(&1.probes))
        IO.puts("#{path}: ok (#{count(config.targets, "target")}, #{count(probes, "probe")})")
        0

      {:error, errors} ->
        CLI.print_issues(errors, path, :stderr)
        IO.puts(:stderr, "#{path}: #{count(errors, "error")}")
        1
    end
  end

  defp count(list, noun) when is_list(list), do: count(length(list), noun)
  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
