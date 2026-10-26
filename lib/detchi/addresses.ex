defmodule Detchi.Addresses do
  @moduledoc """
  The table of the address of each target (docs/basic-design.md, 3.1).

  Only the Resolver of a target writes its row; probes read it on each
  attempt, so they never wait for a lookup. A row holds the address in
  use, or `{:unresolved, errno}` while the host name has never resolved.
  A target without a row has not written `start` yet, and is not
  measured.

  The table is created by `Detchi.Application`, so that it outlives the
  Resolvers.
  """

  @table __MODULE__

  @type entry :: :inet.ip_address() | {:unresolved, atom()}

  @doc "Creates the table. `name` is for tests."
  @spec create(atom()) :: atom()
  def create(name \\ @table),
    do: :ets.new(name, [:named_table, :public, :set, read_concurrency: true])

  @doc "Puts the entry of a target."
  @spec put(atom(), String.t(), entry()) :: true
  def put(table \\ @table, target, entry), do: :ets.insert(table, {target, entry})

  @doc "The entry of a target, or `nil` if it has none yet."
  @spec lookup(atom(), String.t()) :: entry() | nil
  def lookup(table \\ @table, target) do
    case :ets.lookup(table, target) do
      [{^target, entry}] -> entry
      [] -> nil
    end
  end
end
