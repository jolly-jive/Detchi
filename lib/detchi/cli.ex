defmodule Detchi.CLI do
  @moduledoc """
  The escript entry point: `detchi <command>` (docs/basic-design.md, 3).

  The escript is built with `app: nil`, so nothing is started before
  `main/1`; only `detchi run` starts the application.

  Crash dumps are not written unless `ERL_CRASH_DUMP_SECONDS` is set:
  they hold the heaps of processes, and so the credentials of the config
  (docs/basic-design.md, 3). It is set at run time rather than with
  `-env` in the escript, which would win over the one of the user.
  """

  alias Detchi.CLI.{CheckConfig, Run}
  alias Detchi.Config.Issue

  @version Mix.Project.config()[:version]

  @usage """
  Usage: detchi <command>

  Commands:
    run            Run as a service, recording measurements
    check-config   Check the config file and exit
      --fingerprints   Also print the config fingerprint of each target
                       and the canonical JSON it is taken of

  Options:
    -h, --help     Show this help
    --version      Show the version

  The config file is $DETCHI_CONFIG, or /etc/detchi/detchi.yml.
  """

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    unless System.get_env("ERL_CRASH_DUMP_SECONDS"),
      do: System.put_env("ERL_CRASH_DUMP_SECONDS", "0")

    System.halt(run(argv))
  end

  @doc "Runs a command and returns the exit status."
  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    case argv do
      ["run"] ->
        Run.run()

      ["check-config"] ->
        CheckConfig.run()

      ["check-config", "--fingerprints"] ->
        CheckConfig.run(fingerprints: true)

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
