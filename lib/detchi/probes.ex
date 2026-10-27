defmodule Detchi.Probes do
  @moduledoc """
  The supervisor of the probes of one target (docs/basic-design.md, 3.1),
  one `Detchi.Probe` each, under `one_for_one`, so that a probe that
  fails does not take the others with it.
  """

  use Supervisor

  alias Detchi.Probe
  alias Detchi.Config.Target

  @doc """
  Starts the supervisor of the probes of a target.

  Options:

    * `:target` (required): the target, as in the config.
    * `:writer` (required): the Writer of the target.
    * `:table`: the address table. Defaults to `Detchi.Addresses`.
    * `:probe_opts`: more options of every Probe. For tests.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    %Target{} = target = Keyword.fetch!(opts, :target)

    common =
      [target: target.name, writer: Keyword.fetch!(opts, :writer), snmp: target.snmp]
      |> Keyword.merge(Keyword.take(opts, [:table]))
      |> Keyword.merge(Keyword.get(opts, :probe_opts, []))

    children =
      for probe <- target.probes, do: {Probe, [probe: probe] ++ common}

    Supervisor.init(children, strategy: :one_for_one)
  end
end
