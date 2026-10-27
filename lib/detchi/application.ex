defmodule Detchi.Application do
  @moduledoc false

  use Application

  # Started only by `detchi run`, which puts the validated config in the
  # application environment first, and the config of the SNMP manager in
  # that of snmp, which is started before (see Detchi.CLI.Run).
  @impl true
  def start(_type, _args) do
    Detchi.Snmp.register_user()

    # Owned by the process that runs start/2, which lives as long as the
    # application, so that the table outlives the Resolvers.
    Detchi.Addresses.create()

    # The registry comes first: the Writers register as they start.
    children = [
      Detchi.Registry,
      {Detchi.Targets, config: Application.fetch_env!(:detchi, :config)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Detchi.Supervisor)
  end

  # The files of the SNMP manager; snmp is stopped after Detchi, but has
  # them open already.
  @impl true
  def stop(_state) do
    with {:ok, dir} <- Application.fetch_env(:detchi, :snmp_dir), do: File.rm_rf(dir)
    :ok
  end
end
