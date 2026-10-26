defmodule Detchi.Registry do
  @moduledoc """
  The registry of the Writer of each target (docs/basic-design.md, 3.1).

  A Writer is started with the name `writer/2` gives, and the Resolver
  and the probes of the target are given the same name. The name stays
  good when the Writer is restarted, and it can be given before the
  Writer starts, as the specs of a target's children are made. The Clock
  finds all the Writers with `writers/1`.

  Only Writers are registered: no one else looks up a Resolver or a
  probe.

  A registered Writer is linked to the registry. If the registry is
  restarted, its entries are lost, and the Writers stop on the exit
  signal; their target's supervisor starts them again, and they register
  again.
  """

  @registry __MODULE__

  @doc "The child spec of the registry. `:name` is for tests."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, @registry)
    Registry.child_spec(keys: :unique, name: name)
  end

  @doc "The name of the Writer of a target."
  @spec writer(atom(), String.t()) :: GenServer.name()
  def writer(registry \\ @registry, target), do: {:via, Registry, {registry, {:writer, target}}}

  @doc "The Writers registered now, as `{target, pid}`, by target."
  @spec writers(atom()) :: [{String.t(), pid()}]
  def writers(registry \\ @registry) do
    registry
    |> Registry.select([{{{:writer, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.sort()
  end
end
