defmodule Detchi.CLI.Run do
  @moduledoc """
  `detchi run`: loads the config, starts the application and waits.

  SIGTERM is left to OTP's default handling, which calls `init:stop/0`:
  the application is stopped, its children's `terminate/2` run, and the
  VM exits with 0 (docs/basic-design.md, 3).

  Before it starts, it checks that ICMP sockets can be opened for the
  ICMP probes (docs/basic-design.md, 4): if not, every ICMP line would be
  a failure, and the records would still look alive to `detchi status`.
  """

  require Logger

  alias Detchi.{CLI, Config, Icmp}
  alias Detchi.Config.Issue

  @spec run() :: 1 | no_return()
  def run do
    path = Config.path()

    case Config.load(path) do
      {:ok, config, warnings} ->
        Enum.each(warnings, &Logger.warning(Issue.format(&1, path)))

        case check_icmp(config) do
          :ok ->
            Application.put_env(:detchi, :config, config)
            {:ok, _} = Application.ensure_all_started(:detchi)
            Process.sleep(:infinity)

          {:error, message} ->
            IO.puts(:stderr, "detchi: #{message}")
            1
        end

      {:error, errors} ->
        CLI.print_issues(errors, path, :stderr)
        1
    end
  end

  @doc false
  @spec check_icmp(Config.t(), (:inet | :inet6 -> :ok | {:error, atom()})) ::
          :ok | {:error, String.t()}
  def check_icmp(config, check \\ &Icmp.check/1) do
    config.targets
    |> Icmp.families()
    |> Enum.find_value(:ok, fn family ->
      case check.(family) do
        :ok -> nil
        {:error, errno} -> {:error, Icmp.describe(family, errno)}
      end
    end)
  end
end
