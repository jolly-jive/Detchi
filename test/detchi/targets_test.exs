defmodule Detchi.TargetsTest do
  use ExUnit.Case, async: true

  alias Detchi.{Addresses, Config}
  alias Detchi.Config.{Probe, Target}

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp target(name, address),
    do: %Target{
      name: name,
      host: :inet.ntoa(address) |> to_string(),
      address: address,
      family: :auto,
      probes: [%Probe{name: "ping", protocol: :icmp, interval_ms: 60_000, timeout_ms: 1000}]
    }

  test "starts a Target for each target of the config", %{tmp_dir: dir, test: test} do
    registry = :"#{test}.registry"
    start_supervised!({Detchi.Registry, name: registry})
    table = Addresses.create(:"#{test}.addresses")

    config = %Config{
      data_dir: dir,
      retention_days: 1827,
      compression: :gzip,
      resolve_interval_ms: 300_000,
      targets: [target("sw1", {192, 0, 2, 2}), target("core1", {192, 0, 2, 1})]
    }

    sup =
      start_supervised!(
        {Detchi.Targets,
         config: config,
         name: :"#{test}.targets",
         registry: registry,
         table: table,
         writer_opts: [housekeeper: self()]}
      )

    assert [{Detchi.Target, "sw1"}, {Detchi.Target, "core1"}] ==
             Supervisor.which_children(sup) |> Enum.map(&elem(&1, 0)) |> Enum.reverse()

    assert [{"core1", _}, {"sw1", _}] = Detchi.Registry.writers(registry)
  end
end
