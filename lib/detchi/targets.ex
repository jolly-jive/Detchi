defmodule Detchi.Targets do
  @moduledoc """
  The supervisor of all the targets (docs/basic-design.md, 3.1), one
  `Detchi.Target` each, under `one_for_one`.

  The targets are those of the config at start. A config change is
  applied by restarting (docs/basic-design.md, 7.9), so they are fixed.
  """

  use Supervisor

  alias Detchi.Config

  @doc """
  Starts the supervisor of the targets of a config.

  Options:

    * `:config` (required): the validated config.
    * `:name`: the name of the process. Defaults to `Detchi.Targets`.
    * `:registry`, `:table`: as `Detchi.Target` takes them. For tests.
    * `:writer_opts`, `:resolver_opts`, `:probe_opts`: as
      `Detchi.Target` takes them, for all the targets. For tests.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {%Config{} = config, opts} = Keyword.pop!(opts, :config)

    children =
      Enum.map(config.targets, fn target ->
        {Detchi.Target,
         [
           target: target,
           data_dir: config.data_dir,
           resolve_interval_ms: config.resolve_interval_ms
         ] ++ opts}
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
