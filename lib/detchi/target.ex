defmodule Detchi.Target do
  @moduledoc """
  The supervisor of one target (docs/basic-design.md, 3.1).

  The children are, in this order, the Writer, the Resolver and the
  probes (`Detchi.Probes`), under `rest_for_one`: each needs the ones
  before it. On shutdown they stop in the reverse order, so the probes
  count what they cut off before the Writer writes `stop` last. When the
  Writer is restarted, the others are restarted too, and `start` is
  written again.

  The Writer is registered in `Detchi.Registry`, and the others are given
  its name, so that they reach the Writer after it is restarted.
  """

  use Supervisor

  alias Detchi.{Probes, Resolver, Writer}
  alias Detchi.Config.Target

  @type option ::
          {:target, Target.t()}
          | {:data_dir, Path.t()}
          | {:resolve_interval_ms, pos_integer()}
          | {:registry, atom()}
          | {:table, atom()}
          | {:writer_opts, keyword()}
          | {:resolver_opts, keyword()}
          | {:probe_opts, keyword()}

  @doc """
  Starts the supervisor of a target.

  Options:

    * `:target` (required): the target, as in the config.
    * `:data_dir` (required): the directory of the records.
    * `:resolve_interval_ms` (required): how often a host name is looked
      up again.
    * `:registry`: the registry of the Writers. Defaults to
      `Detchi.Registry`.
    * `:table`: the address table. Defaults to `Detchi.Addresses`.
    * `:writer_opts`, `:resolver_opts`, `:probe_opts`: more options of
      the Writer, the Resolver and every Probe. For tests.
  """
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @doc false
  def child_spec(opts) do
    %Target{name: name} = Keyword.fetch!(opts, :target)
    %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  @impl true
  def init(opts) do
    %Target{} = target = Keyword.fetch!(opts, :target)
    writer = Detchi.Registry.writer(Keyword.get(opts, :registry, Detchi.Registry), target.name)
    table = Keyword.get(opts, :table, Detchi.Addresses)

    writer_opts =
      [target: target, data_dir: Keyword.fetch!(opts, :data_dir), name: writer]
      |> Keyword.merge(Keyword.get(opts, :writer_opts, []))

    resolver_opts =
      [
        target: target,
        writer: writer,
        resolve_interval_ms: Keyword.fetch!(opts, :resolve_interval_ms),
        table: table
      ]
      |> Keyword.merge(Keyword.get(opts, :resolver_opts, []))

    probes_opts = [
      target: target,
      writer: writer,
      table: table,
      probe_opts: Keyword.get(opts, :probe_opts, [])
    ]

    Supervisor.init(
      [{Writer, writer_opts}, {Resolver, resolver_opts}, {Probes, probes_opts}],
      strategy: :rest_for_one
    )
  end
end
