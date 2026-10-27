defmodule Detchi.SnmpTest do
  # snmp is one application for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Detchi.Config.{Credential, Probe, Target}
  alias Detchi.{Addresses, Snmp}

  @moduletag :capture_log

  @community "s3cr3t-community"
  @credential %Credential{name: "campus-v2c", version: :v2c, community: @community}
  @wrong %Credential{name: "wrong", version: :v2c, community: "wr0ng-community"}

  @sys_descr [1, 3, 6, 1, 2, 1, 1, 1, 0]
  @sys_uptime [1, 3, 6, 1, 2, 1, 1, 3, 0]
  # A long sysDescr makes a reply of a few of them too big for the
  # agent, which takes 484 bytes.
  @descr String.duplicate("d", 200)

  @probe %Probe{
    name: "uptime",
    protocol: :snmp,
    interval_ms: 60_000,
    timeout_ms: 1000,
    oids: [@sys_uptime]
  }

  # An agent of OTP (snmpa) in the VM of the tests, on loopback, with
  # the manager configured by Detchi.Snmp (docs/basic-design.md, 9.6).
  setup_all do
    dir = Path.join(System.tmp_dir!(), "detchi-snmp-test-#{System.unique_integer([:positive])}")
    {:ok, manager_dir} = Snmp.configure(dir)
    port = free_port()
    agent_dir = Path.join(dir, "agent")
    write_agent_config(agent_dir, port)

    Application.put_env(:snmp, :agent,
      config: [dir: String.to_charlist(agent_dir), force_load: true],
      db_dir: String.to_charlist(Path.join(agent_dir, "db")),
      agent_verbosity: :silence
    )

    {:ok, _} = Application.ensure_all_started(:snmp)
    :ok = Snmp.register_user()

    on_exit(fn ->
      Application.stop(:snmp)
      File.rm_rf!(dir)
    end)

    %{port: port, manager_dir: manager_dir}
  end

  defp free_port do
    {:ok, socket} = :gen_udp.open(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_udp.close(socket)
    port
  end

  defp write_agent_config(dir, port) do
    File.mkdir_p!(Path.join(dir, "db"))
    conf = String.to_charlist(dir)

    :ok =
      :snmpa_conf.write_agent_config(conf, [
        :snmpa_conf.agent_entry(
          :intAgentTransports,
          [
            {:transportDomainUdpIpv4, {127, 0, 0, 1}},
            {:transportDomainUdpIpv6, {0, 0, 0, 0, 0, 0, 0, 1}}
          ]
        ),
        :snmpa_conf.agent_entry(:intAgentUDPPort, port),
        :snmpa_conf.agent_entry(:snmpEngineID, ~c"agent"),
        :snmpa_conf.agent_entry(:snmpEngineMaxMessageSize, 484)
      ])

    :ok =
      :snmpa_conf.write_standard_config(conf, [
        {:sysDescr, String.to_charlist(@descr)},
        {:sysObjectID, [1, 3, 6, 1, 4, 1, 193, 19]},
        {:sysContact, ~c""},
        {:sysName, ~c"agent"},
        {:sysLocation, ~c""},
        {:sysServices, 72},
        {:snmpEnableAuthenTraps, :disabled}
      ])

    community = String.to_charlist(@community)
    :ok = :snmpa_conf.write_community_config(conf, [{community, community, ~c"all", ~c"", ~c""}])

    :ok =
      :snmpa_conf.write_vacm_config(conf, [
        {:vacmSecurityToGroup, :v2c, ~c"all", ~c"all"},
        {:vacmAccess, ~c"all", ~c"", :any, :noAuthNoPriv, :exact, ~c"all", ~c"", ~c"all"},
        {:vacmViewTreeFamily, ~c"all", [1, 3, 6, 1], :included, :null}
      ])

    :ok = :snmpa_conf.write_context_config(conf, [~c""])
    :ok = :snmpa_conf.write_usm_config(conf, [])
    :ok = :snmpa_conf.write_notify_config(conf, [])
    :ok = :snmpa_conf.write_target_addr_config(conf, [])
    :ok = :snmpa_conf.write_target_params_config(conf, [])
  end

  # Each test registers targets of its own name.
  defp name(test, suffix \\ ""), do: "t#{:erlang.phash2(test)}#{suffix}"

  defp snmp(ctx, credential \\ @credential), do: %{credential: credential, port: ctx.port}

  describe "configure/1" do
    test "writes the config of the manager to a directory of its own", ctx do
      assert Path.basename(ctx.manager_dir) == "detchi-#{System.pid()}"
      assert File.exists?(Path.join(ctx.manager_dir, "manager.conf"))
      assert Keyword.fetch!(Application.fetch_env!(:snmp, :manager), :restart_type) == :permanent
    end
  end

  describe "measure/3" do
    test "an answer is ok, with the varbinds, the address and the port", ctx do
      target = name(ctx.test)
      :ok = Snmp.register(target, {127, 0, 0, 1}, snmp(ctx))
      probe = %{@probe | oids: [@sys_uptime, @sys_descr, [1, 3, 6, 1, 2, 1, 1, 99, 0]]}
      before = System.os_time(:microsecond)

      assert %{
               ts: ts,
               addr: {127, 0, 0, 1},
               port: port,
               status: :ok,
               rtt_us: rtt,
               snmp: %{version: :v2c, op: :get, varbinds: varbinds}
             } = result = Snmp.measure(target, :v2c, probe)

      assert port == ctx.port
      assert map_size(result) == 6
      assert ts >= before and ts <= System.os_time(:microsecond)
      assert rtt > 0 and rtt < 1_000_000

      assert [
               {@sys_uptime, :TimeTicks, ticks},
               {@sys_descr, :"OCTET STRING", descr},
               {[1, 3, 6, 1, 2, 1, 1, 99, 0], :NULL, :noSuchObject}
             ] = varbinds

      assert is_integer(ticks)
      assert to_string(descr) == @descr
    end

    test "an errorStatus is an error with the RTT and without varbinds", ctx do
      target = name(ctx.test)
      :ok = Snmp.register(target, {127, 0, 0, 1}, snmp(ctx))
      probe = %{@probe | oids: List.duplicate(@sys_descr, 5)}

      assert %{status: :error, rtt_us: _, error: {:snmp, :tooBig, 0}, snmp: snmp} =
               Snmp.measure(target, :v2c, probe)

      assert snmp == %{version: :v2c, op: :get}
    end

    test "a wrong community is a timeout, as the agent does not answer", ctx do
      target = name(ctx.test)
      :ok = Snmp.register(target, {127, 0, 0, 1}, snmp(ctx, @wrong))
      started = System.monotonic_time(:millisecond)

      assert %{status: :timeout, timeout_ms: 200, snmp: %{version: :v2c, op: :get}} =
               result = Snmp.measure(target, :v2c, %{@probe | timeout_ms: 200})

      refute Map.has_key?(result, :rtt_us)
      assert (System.monotonic_time(:millisecond) - started) in 200..400
    end

    test "IPv6 goes to the IPv6 address", ctx do
      target = name(ctx.test)
      :ok = Snmp.register(target, {0, 0, 0, 0, 0, 0, 0, 1}, snmp(ctx))

      assert %{status: :ok, addr: {0, 0, 0, 0, 0, 0, 0, 1}} = Snmp.measure(target, :v2c, @probe)
    end

    test "raises for a target that is not registered", ctx do
      assert_raise RuntimeError, "cannot get the address of #{name(ctx.test)} (not_found)", fn ->
        Snmp.measure(name(ctx.test), :v2c, @probe)
      end
    end

    test "raises for a request too large for the manager to send", ctx do
      target = name(ctx.test)
      :ok = Snmp.register(target, {127, 0, 0, 1}, snmp(ctx))

      assert_raise RuntimeError, "sync_get2 failed (send_failed, tooBig)", fn ->
        Snmp.measure(target, :v2c, %{@probe | oids: List.duplicate(@sys_descr, 6000)})
      end
    end
  end

  describe "register/3" do
    test "registers again, at a new address or port", ctx do
      target = name(ctx.test)
      :ok = Snmp.register(target, {127, 0, 0, 1}, %{snmp(ctx) | port: free_port()})
      assert %{status: :timeout} = Snmp.measure(target, :v2c, %{@probe | timeout_ms: 100})

      :ok = Snmp.register(target, {127, 0, 0, 1}, snmp(ctx))
      assert %{status: :ok, port: port} = Snmp.measure(target, :v2c, @probe)
      assert port == ctx.port

      :ok = Snmp.register(target, {127, 0, 0, 1}, snmp(ctx))
      assert %{status: :ok} = Snmp.measure(target, :v2c, @probe)
    end
  end

  describe "through a Target" do
    @describetag :tmp_dir

    setup %{test: test} do
      registry = :"#{test}.registry"
      start_supervised!({Detchi.Registry, name: registry})
      %{registry: registry, table: Addresses.create(:"#{test}.addresses")}
    end

    defp start_target(ctx, target) do
      start_supervised!(
        {Detchi.Target,
         target: target,
         data_dir: ctx.tmp_dir,
         resolve_interval_ms: 3_600_000,
         registry: ctx.registry,
         table: ctx.table,
         writer_opts: [housekeeper: self()]}
      )
    end

    defp lines(ctx, target) do
      :sys.get_state(Detchi.Registry.writer(ctx.registry, target))

      Path.wildcard(Path.join([ctx.tmp_dir, target, "*.jsonl"]))
      |> Enum.flat_map(&(&1 |> File.read!() |> String.split("\n", trim: true)))
      |> Enum.map(&:json.decode/1)
    end

    defp resolver(sup) do
      Enum.find_value(Supervisor.which_children(sup), fn
        {Detchi.Resolver, pid, _, _} -> pid
        _ -> nil
      end)
    end

    defp wait_until(fun, tries \\ 100) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("timed out")
        true -> Process.sleep(20) && wait_until(fun, tries - 1)
      end
    end

    test "the Resolver registers the target, again when restarted, and the probe measures",
         ctx do
      name = name(ctx.test)

      target = %Target{
        name: name,
        host: "127.0.0.1",
        address: {127, 0, 0, 1},
        family: :auto,
        snmp: snmp(ctx),
        probes: [%{@probe | interval_ms: 100, timeout_ms: 50}]
      }

      log =
        capture_log(fn ->
          sup = start_target(ctx, target)
          wait_until(fn -> Enum.any?(lines(ctx, name), & &1["protocol"]) end)

          old = resolver(sup)
          ref = Process.monitor(old)
          Process.exit(old, :kill)
          assert_receive {:DOWN, ^ref, _, _, _}
          wait_until(fn -> resolver(sup) not in [nil, old] end)

          count = length(lines(ctx, name))
          wait_until(fn -> length(lines(ctx, name)) > count + 1 end)
        end)

      lines = lines(ctx, name)
      refute Enum.any?(lines, &(&1["status"] not in [nil, "ok"]))
      assert Enum.count(lines, &(&1["event"] == "start")) >= 2

      assert %{
               "probe" => "uptime",
               "protocol" => "snmp",
               "addr" => "127.0.0.1",
               "port" => port,
               "status" => "ok",
               "snmp" => %{
                 "version" => "v2c",
                 "op" => "get",
                 "varbinds" => [%{"oid" => "1.3.6.1.2.1.1.3.0", "type" => "TimeTicks"}]
               }
             } = Enum.find(lines, & &1["protocol"])

      assert port == ctx.port
      refute log =~ @community
    end

    test "a failure of snmpm is internal, with the port, and keeps the community out", ctx do
      name = name(ctx.test)

      # Not registered: the Resolver is told to leave it out.
      target = %Target{
        name: name,
        host: "127.0.0.1",
        address: {127, 0, 0, 1},
        family: :auto,
        snmp: snmp(ctx),
        probes: [%{@probe | interval_ms: 100, timeout_ms: 50}]
      }

      log =
        capture_log(fn ->
          start_supervised!(
            {Detchi.Target,
             target: target,
             data_dir: ctx.tmp_dir,
             resolve_interval_ms: 3_600_000,
             registry: ctx.registry,
             table: ctx.table,
             writer_opts: [housekeeper: self()],
             resolver_opts: [register: fn _ -> :ok end]}
          )

          wait_until(fn -> Enum.any?(lines(ctx, name), & &1["protocol"]) end)
        end)

      assert %{
               "status" => "error",
               "error" => %{"reason" => "internal"},
               "port" => port,
               "snmp" => %{"version" => "v2c", "op" => "get"}
             } = Enum.find(lines(ctx, name), & &1["protocol"])

      assert port == ctx.port
      assert log =~ "cannot get the address of #{name} (not_found)"
      refute log =~ @community
    end
  end

  test "Record encodes the result of measure/3", ctx do
    target = name(ctx.test)
    :ok = Snmp.register(target, {127, 0, 0, 1}, snmp(ctx))
    result = Snmp.measure(target, :v2c, %{@probe | oids: [@sys_uptime, @sys_descr]})

    line =
      %{target: target, probe: "uptime", protocol: :snmp}
      |> Map.merge(result)
      |> Detchi.Record.encode()
      |> IO.iodata_to_binary()

    assert line =~ ~s("addr":"127.0.0.1","port":#{ctx.port},"status":"ok")
    assert line =~ ~s({"oid":"1.3.6.1.2.1.1.1.0","type":"OctetString","value":"#{@descr}"})
  end
end
