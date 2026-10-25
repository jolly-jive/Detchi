defmodule Detchi.CLI.CheckConfig do
  @moduledoc """
  `detchi check-config`: checks the config file without starting
  anything (docs/basic-design.md, 7.9).

  Exits with 0 when the config is valid, warnings or not, and with 1
  when it is not. Errors go to stderr, the rest to stdout.

  With `fingerprints: true`, a valid config also prints two lines for
  each target, before the summary: `<target> <config_hash>` and
  `<target> <canonical JSON>`. Both start with the target name, so the
  output of two configs can be compared with `diff`, or one target picked
  out with `grep`.
  """

  alias Detchi.{CLI, Config}
  alias Detchi.Config.Fingerprint

  @spec run(keyword()) :: 0 | 1
  def run(opts \\ []) do
    path = Config.path()

    case Config.load(path) do
      {:ok, config, warnings} ->
        CLI.print_issues(warnings, path, :stdio)
        if opts[:fingerprints], do: Enum.each(config.targets, &print_fingerprint/1)
        probes = Enum.sum_by(config.targets, &length(&1.probes))
        IO.puts("#{path}: ok (#{count(config.targets, "target")}, #{count(probes, "probe")})")
        0

      {:error, errors} ->
        CLI.print_issues(errors, path, :stderr)
        IO.puts(:stderr, "#{path}: #{count(errors, "error")}")
        1
    end
  end

  defp print_fingerprint(target) do
    IO.puts("#{target.name} #{Fingerprint.hash(target)}")
    IO.puts("#{target.name} #{Fingerprint.canonical(target)}")
  end

  defp count(list, noun) when is_list(list), do: count(length(list), noun)
  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
