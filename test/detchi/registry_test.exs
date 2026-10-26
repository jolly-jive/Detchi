defmodule Detchi.RegistryTest do
  use ExUnit.Case, async: true

  setup %{test: test} do
    registry = :"#{test}"
    start_supervised!({Detchi.Registry, name: registry})
    %{registry: registry}
  end

  defp start_named(registry, target) do
    name = Detchi.Registry.writer(registry, target)
    {:ok, pid} = Agent.start(fn -> target end, name: name)
    pid
  end

  test "a Writer is reached by the name of its target", %{registry: registry} do
    start_named(registry, "core1")
    assert Agent.get(Detchi.Registry.writer(registry, "core1"), & &1) == "core1"
  end

  test "writers/1 gives all the Writers, by target", %{registry: registry} do
    sw1 = start_named(registry, "sw1")
    core1 = start_named(registry, "core1")
    assert Detchi.Registry.writers(registry) == [{"core1", core1}, {"sw1", sw1}]
  end

  test "an entry goes with its process", %{registry: registry} do
    pid = start_named(registry, "core1")
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}

    # The new process takes the name even if the registry has not seen the
    # old one go.
    new = start_named(registry, "core1")
    assert Detchi.Registry.writers(registry) == [{"core1", new}]
  end
end
