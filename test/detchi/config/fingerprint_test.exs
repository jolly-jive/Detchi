defmodule Detchi.Config.FingerprintTest do
  use ExUnit.Case, async: true

  alias Detchi.Config
  alias Detchi.Config.Fingerprint

  @moduletag :tmp_dir

  @secret "s3cr3t-community"

  defp targets(dir, text) do
    path = Path.join(dir, "detchi-#{System.unique_integer([:positive])}.yml")
    File.write!(path, text)
    assert {:ok, %Config{targets: targets}, _} = Config.load(path)
    targets
  end

  defp hash(dir, text) do
    [target] = targets(dir, text)
    Fingerprint.hash(target)
  end

  test "canonicalizes the sample config", %{tmp_dir: dir} do
    [core1, sw1, _] = targets(dir, File.read!("test/fixtures/config/sample.yml"))

    assert Fingerprint.canonical(core1) ==
             ~s({"family":"auto","host":"192.0.2.1","name":"core1","probes":[) <>
               ~s({"interval_ms":60000,"name":"dns","port":53,"protocol":"udp","service":"dns","timeout_ms":1000},) <>
               ~s({"interval_ms":300000,"name":"if-uplink","oids":["1.3.6.1.2.1.1.3.0","1.3.6.1.2.1.31.1.1.1.1.1","1.3.6.1.2.1.31.1.1.1.6.1"],"protocol":"snmp","timeout_ms":5000},) <>
               ~s({"interval_ms":60000,"name":"ping","protocol":"icmp","timeout_ms":1000},) <>
               ~s({"interval_ms":60000,"name":"ssh","port":22,"protocol":"tcp","timeout_ms":1000}],) <>
               ~s("snmp":{"port":161,"version":"v2c"}})

    assert Fingerprint.canonical(sw1) ==
             ~s({"family":"auto","host":"sw1.example.net","name":"sw1","probes":[) <>
               ~s({"interval_ms":60000,"name":"ping","protocol":"icmp","timeout_ms":1000},) <>
               ~s({"interval_ms":60000,"name":"ssh","port":22,"protocol":"tcp","timeout_ms":1000}]})

    assert Fingerprint.hash(core1) ==
             "sha256:" <>
               Base.encode16(:crypto.hash(:sha256, Fingerprint.canonical(core1)), case: :lower)

    assert Fingerprint.hash(core1) =~ ~r/\Asha256:[0-9a-f]{64}\z/
  end

  test "leaves out credentials and the profile name", %{tmp_dir: dir} do
    config = fn profile, community ->
      """
      credentials:
        #{profile}: { version: v2c, community: "#{community}" }
      targets:
        - name: t
          host: 192.0.2.1
          snmp: { credential: #{profile} }
          probes: [{ name: up, protocol: snmp, oids: ["1.3.6.1.2.1.1.3.0"] }]
      """
    end

    [target] = targets(dir, config.("campus-v2c", @secret))
    refute Fingerprint.canonical(target) =~ @secret
    refute Fingerprint.canonical(target) =~ "campus-v2c"

    assert Fingerprint.hash(target) == hash(dir, config.("other", "public"))
  end

  test "is the same for the same measurement written differently", %{tmp_dir: dir} do
    written = """
    targets:
      - name: t
        host: 192.0.2.1
        probes:
          - { name: ssh, protocol: tcp, port: 22, interval: 1m }
          - { name: ping, protocol: icmp }
    """

    filled = """
    defaults: { interval: 60s, timeout: 1000ms }
    targets:
      - name: t
        host: 192.0.2.1
        family: auto
        probes:
          - { name: ping, protocol: icmp, interval: 60000ms, timeout: 1s }
          - { name: ssh, protocol: tcp, port: 22, interval: 60s, timeout: 1s }
    """

    assert hash(dir, written) == hash(dir, filled)
  end

  test "changes with what is measured", %{tmp_dir: dir} do
    base = """
    defaults: { interval: 60s }
    credentials:
      p: { version: v2c, community: c }
    targets:
      - name: t
        host: 192.0.2.1
        snmp: { credential: p, port: 161 }
        probes:
          - name: up
            protocol: snmp
            oids: ["1.3.6.1.2.1.1.3.0", "1.3.6.1.2.1.1.5.0"]
    """

    changes = [
      {"defaults: { interval: 60s }", "defaults: { interval: 30s }"},
      {"host: 192.0.2.1", "host: 192.0.2.2"},
      {"port: 161", "port: 1161"},
      {"name: up", "name: uptime"},
      {~s("1.3.6.1.2.1.1.3.0", "1.3.6.1.2.1.1.5.0"), ~s("1.3.6.1.2.1.1.5.0", "1.3.6.1.2.1.1.3.0")}
    ]

    for {from, to} <- changes do
      changed = String.replace(base, from, to)
      assert changed != base
      refute hash(dir, changed) == hash(dir, base), to
    end
  end
end
