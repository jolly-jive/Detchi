defmodule Detchi.Application do
  @moduledoc false

  use Application

  # Started only by `detchi run`, which puts the validated config in the
  # application environment first (see Detchi.CLI.Run).
  @impl true
  def start(_type, _args) do
    # Owned by the process that runs start/2, which lives as long as the
    # application, so that the table outlives the Resolvers.
    Detchi.Addresses.create()

    children = []

    Supervisor.start_link(children, strategy: :one_for_one, name: Detchi.Supervisor)
  end
end
