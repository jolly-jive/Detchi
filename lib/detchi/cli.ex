defmodule Detchi.CLI do
  @moduledoc """
  The escript entry point: `detchi <command>` (docs/basic-design.md, 3).

  The escript is built with `app: nil`, so nothing is started before
  `main/1`; only `detchi run` starts the application.
  """

  alias Detchi.CLI.{CheckConfig, Run}
  alias Detchi.Config.Issue

  @version Mix.Project.config()[:version]

  @usage """
  Usage: detchi <command>

  Commands:
    run            Run as a service, recording measurements
    check-config   Check the config file and exit

  Options:
    -h, --help     Show this help
    --version      Show the version

  The config file is $DETCHI_CONFIG, or /etc/detchi/detchi.yml.
  """

  @spec main([String.t()]) :: no_return()
  def main(argv), do: System.halt(run(argv))

  @doc "Runs a command and returns the exit status."
  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    case argv do
      ["run"] ->
        Run.run()

      ["check-config"] ->
        CheckConfig.run()

      [help] when help in ["-h", "--help"] ->
        IO.write(@usage)
        0

      ["--version"] ->
        IO.puts("detchi #{@version}")
        0

      _ ->
        IO.write(:stderr, @usage)
        2
    end
  end

  @doc "The version of Detchi."
  @spec version() :: String.t()
  def version, do: @version

  @doc false
  def print_issues(issues, file, device) do
    Enum.each(issues, &IO.puts(device, Issue.format(&1, file)))
  end
end
