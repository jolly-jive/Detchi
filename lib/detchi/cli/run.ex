defmodule Detchi.CLI.Run do
  @moduledoc """
  `detchi run`: loads the config, starts the application and waits.

  SIGTERM is left to OTP's default handling, which calls `init:stop/0`:
  the application is stopped, its children's `terminate/2` run, and the
  VM exits with 0 (docs/basic-design.md, 3).
  """

  require Logger

  alias Detchi.{CLI, Config}
  alias Detchi.Config.Issue

  @spec run() :: 1 | no_return()
  def run do
    path = Config.path()

    case Config.load(path) do
      {:ok, config, warnings} ->
        Application.put_env(:detchi, :config, config)
        {:ok, _} = Application.ensure_all_started(:detchi)
        Enum.each(warnings, &Logger.warning(Issue.format(&1, path)))
        Process.sleep(:infinity)

      {:error, errors} ->
        CLI.print_issues(errors, path, :stderr)
        1
    end
  end
end
