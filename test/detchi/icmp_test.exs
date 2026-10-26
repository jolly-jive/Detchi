defmodule Detchi.IcmpTest do
  use ExUnit.Case, async: true

  alias Detchi.Config.{Probe, Target}
  alias Detchi.Icmp

  @probe %Probe{name: "ping", protocol: :icmp, interval_ms: 60_000, timeout_ms: 1000}

  # TEST-NET-1 (RFC 5737): sent through the default route, and nobody
  # answers.
  @silent {192, 0, 2, 1}

  describe "measure/3 on loopback" do
    test "an answered Echo is ok, with the RTT" do
      before = System.os_time(:microsecond)
      assert %{ts: ts, status: :ok, rtt_us: rtt} = Icmp.measure({127, 0, 0, 1}, @probe)
      assert ts >= before and ts <= System.os_time(:microsecond)
      assert rtt >= 0 and rtt < 1_000_000
    end

    test "ICMPv6 is answered too" do
      assert %{status: :ok, rtt_us: _} = Icmp.measure({0, 0, 0, 0, 0, 0, 0, 1}, @probe)
    end
  end

  # These need a default route, and a first router that sends Time
  # Exceeded. Leave them out with `mix test --exclude network`.
  describe "measure/3 through the network" do
    @describetag :network

    test "no answer is a timeout, after the timeout of the probe" do
      started = System.monotonic_time(:millisecond)

      assert %{ts: _, status: :timeout, timeout_ms: 300} =
               result = Icmp.measure(@silent, %{@probe | timeout_ms: 300})

      assert map_size(result) == 3
      assert System.monotonic_time(:millisecond) - started >= 300
    end

    test "Time Exceeded is unreachable, with the type, the code, the router and the RTT" do
      assert %{status: :unreachable, error: {:icmp, 11, 0, from}, rtt_us: rtt} =
               Icmp.measure(@silent, @probe, ttl: 1)

      assert {_, _, _, _} = from
      assert rtt > 0
    end
  end

  test "check/1 opens an ICMP socket" do
    assert Icmp.check(:inet) == :ok
    assert Icmp.check(:inet6) == :ok
  end

  test "families/1 takes the families of the targets with ICMP probes" do
    ping = @probe
    ssh = %Probe{name: "ssh", protocol: :tcp, interval_ms: 60_000, timeout_ms: 1000, port: 22}

    target = fn name, host, address, family, probes ->
      %Target{name: name, host: host, address: address, family: family, probes: probes}
    end

    assert Icmp.families([]) == []
    assert Icmp.families([target.("a", "192.0.2.1", {192, 0, 2, 1}, :auto, [ping])]) == [:inet]
    assert Icmp.families([target.("a", "a.example.net", nil, :auto, [ping])]) == [:inet]
    assert Icmp.families([target.("a", "a.example.net", nil, :ipv4, [ping])]) == [:inet]
    assert Icmp.families([target.("a", "a.example.net", nil, :ipv6, [ping])]) == [:inet6]

    assert Icmp.families([
             target.("a", "2001:db8::1", {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, :auto, [ping])
           ]) ==
             [:inet6]

    assert Icmp.families([
             target.("a", "a.example.net", nil, :ipv6, [ping]),
             target.("b", "b.example.net", nil, :auto, [ping]),
             target.("c", "c.example.net", nil, :ipv6, [ssh])
           ]) == [:inet, :inet6]

    assert Icmp.families([target.("a", "a.example.net", nil, :ipv6, [ssh])]) == []
  end

  test "describe/2 names ping_group_range when permission is denied" do
    assert Icmp.describe(:inet, :eacces) ==
             "cannot open an ICMP socket (eacces); " <>
               "net.ipv4.ping_group_range does not include the groups of this user"

    assert Icmp.describe(:inet6, :eafnosupport) == "cannot open an ICMPv6 socket (eafnosupport)"
  end
end
