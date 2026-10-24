defmodule Detchi.Config.ValidatorTest do
  use ExUnit.Case, async: true

  alias Detchi.Config
  alias Detchi.Config.{Credential, Issue, Probe, Target, Validator, Yaml}

  @sample File.read!("test/fixtures/config/sample.yml")

  defp validate(yaml) do
    {:ok, root} = Yaml.parse(yaml)
    Validator.validate(root)
  end

  # The errors as {path, reason}, in file order.
  defp errors(yaml) do
    assert {:error, issues} = validate(yaml)
    Enum.map(issues, &{Issue.format_path(&1.path), &1.reason})
  end

  defp target(target_yaml) do
    "credentials: { c: { version: v2c, community: x } }\ntargets:\n  - " <> target_yaml
  end

  defp probe(probe_yaml) do
    target("{ name: t, host: 192.0.2.1, snmp: { credential: c }, probes: [#{probe_yaml}] }")
  end

  describe "the sample config" do
    test "is valid and fills in the defaults" do
      assert {:ok, %Config{} = config, []} = validate(@sample)

      assert config.data_dir == "/var/lib/detchi"
      assert config.retention_days == 1827
      assert config.compression == :gzip
      assert config.resolve_interval_ms == 300_000

      assert [core1, sw1, sw2] = config.targets

      assert %Target{
               name: "core1",
               host: "192.0.2.1",
               address: {192, 0, 2, 1},
               family: :auto,
               snmp: %{credential: %Credential{name: "campus-v2c", version: :v2c}, port: 161}
             } = core1

      assert [
               %Probe{name: "ping", protocol: :icmp, interval_ms: 60_000, timeout_ms: 1_000},
               %Probe{name: "ssh", protocol: :tcp, port: 22},
               %Probe{name: "dns", protocol: :udp, service: :dns, port: 53},
               %Probe{name: "if-uplink", protocol: :snmp, interval_ms: 300_000, timeout_ms: 5_000}
             ] = core1.probes

      assert List.last(core1.probes).oids == [
               [1, 3, 6, 1, 2, 1, 1, 3, 0],
               [1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 1, 1],
               [1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 6, 1]
             ]

      assert %Target{host: "sw1.example.net", address: nil, snmp: nil} = sw1
      assert %Target{address: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x12}, family: :ipv6} = sw2
      assert Enum.map(sw1.probes, & &1.name) == ["ping", "ssh"]
    end
  end

  describe "defaults" do
    test "apply the built-in values when the section is absent" do
      assert {:ok, config, []} =
               validate(
                 probe(
                   "{ name: a, protocol: icmp }, { name: b, protocol: snmp, oids: [\"1.3\"] }"
                 )
               )

      assert [%{probes: [icmp, snmp]}] = config.targets
      assert {icmp.interval_ms, icmp.timeout_ms} == {60_000, 1_000}
      assert {snmp.interval_ms, snmp.timeout_ms} == {60_000, 5_000}
    end

    test "timeout does not apply to SNMP probes, snmp_timeout does" do
      yaml =
        "defaults: { timeout: 2s, snmp_timeout: 10s }\n" <>
          probe("{ name: a, protocol: icmp }, { name: b, protocol: snmp, oids: [\"1.3\"] }")

      assert {:ok, config, []} = validate(yaml)
      assert [%{probes: [%{timeout_ms: 2_000}, %{timeout_ms: 10_000}]}] = config.targets
    end

    test "a probe's own values win" do
      yaml =
        "defaults: { interval: 10s }\n" <>
          probe("{ name: a, protocol: icmp, interval: 1m, timeout: 3s }")

      assert {:ok, config, []} = validate(yaml)
      assert [%{probes: [%{interval_ms: 60_000, timeout_ms: 3_000}]}] = config.targets
    end

    test "a UDP port defaults to the service's port" do
      yaml =
        probe(
          "{ name: a, protocol: udp, service: ntp }, { name: b, protocol: udp, service: quic }, { name: c, protocol: udp, service: dns, port: 5353 }"
        )

      assert {:ok, config, _} = validate(yaml)
      assert [%{probes: probes}] = config.targets
      assert Enum.map(probes, & &1.port) == [123, 443, 5353]
    end
  end

  describe "keys" do
    test "unknown keys are errors at every level" do
      yaml = """
      colour: red
      defaults: { jitter: 1s }
      credentials: { c: { version: v2c, community: x, retries: 1 } }
      targets:
        - name: t
          host: 192.0.2.1
          group: x
          snmp: { credential: c, community: x }
          probes: [{ name: a, protocol: icmp, port: 1 }]
      """

      assert errors(yaml) == [
               {"", :unknown_key},
               {"defaults", :unknown_key},
               {"credentials.c", :unknown_key},
               {"targets[0]", :unknown_key},
               {"targets[0].snmp", :unknown_key},
               {"targets[0].probes[0]", :unknown_key}
             ]
    end

    test "top-level x- keys are ignored, others are not" do
      assert {:ok, _, []} =
               validate("x-anything: { a: 1 }\n" <> probe("{ name: a, protocol: icmp }"))

      assert errors(probe("{ name: a, protocol: icmp, x-note: 1 }")) ==
               [{"targets[0].probes[0]", :unknown_key}]
    end

    test "a merge key is an unknown key" do
      yaml = """
      x-base: &base
        protocol: icmp
      targets:
        - { name: t, host: 192.0.2.1, probes: [{ name: a, <<: *base }] }
      """

      assert {"targets[0].probes[0]", :unknown_key} in errors(yaml)
    end

    test "duplicated keys are errors" do
      yaml = "data_dir: /a\ndata_dir: /b\n" <> probe("{ name: a, name: b, protocol: icmp }")

      assert errors(yaml) == [
               {"data_dir", :duplicate_key},
               {"targets[0].probes[0].name", :duplicate_key}
             ]
    end

    test "missing required keys are errors" do
      assert errors("data_dir: /a\n") == [{"", :missing_key}]

      assert errors(target("{ probes: [{ protocol: icmp }] }")) == [
               {"targets[0]", :missing_key},
               {"targets[0]", :missing_key},
               {"targets[0].probes[0]", :missing_key}
             ]

      assert errors(
               probe(
                 "{ name: a, protocol: tcp }, { name: b, protocol: udp }, { name: c, protocol: snmp }"
               )
             ) ==
               [
                 {"targets[0].probes[0]", :missing_key},
                 {"targets[0].probes[1]", :missing_key},
                 {"targets[0].probes[2]", :missing_key}
               ]
    end

    test "without a valid protocol, keys of any protocol pass and others do not" do
      assert errors(probe("{ name: a, port: 22, oids: [\"1.3\"], bogus: 1 }")) ==
               [{"targets[0].probes[0]", :missing_key}, {"targets[0].probes[0]", :unknown_key}]

      assert errors(probe("{ name: a, protocol: gopher, service: dns, bogus: 1 }")) ==
               [
                 {"targets[0].probes[0].protocol", :invalid_value},
                 {"targets[0].probes[0]", :unknown_key}
               ]
    end

    test "keys of another protocol are unknown" do
      assert errors(
               probe(
                 "{ name: a, protocol: icmp, oids: [\"1.3\"] }, { name: b, protocol: tcp, port: 22, service: dns }"
               )
             ) ==
               [{"targets[0].probes[0]", :unknown_key}, {"targets[0].probes[1]", :unknown_key}]
    end
  end

  describe "values" do
    test "types are strict" do
      yaml = """
      data_dir: relative/dir
      retention_days: 0
      compression: xz
      resolve_interval: 300
      targets:
        - { name: t, host: 192.0.2.1, probes: [{ name: a, protocol: snmp, oids: [1.3] }] }
      """

      assert errors(yaml) == [
               {"data_dir", :invalid_path},
               {"retention_days", :invalid_integer},
               {"compression", :invalid_value},
               {"resolve_interval", :invalid_duration},
               {"targets[0].probes[0].oids[0]", :invalid_oid}
             ]
    end

    test "names follow the file name rule" do
      for name <- ["Core1", ".hidden", "-a", "a b", "a:b", "\"\"", String.duplicate("a", 64)] do
        assert errors(
                 target(
                   "{ name: #{name}, host: 192.0.2.1, probes: [{ name: a, protocol: icmp }] }"
                 )
               ) ==
                 [{"targets[0].name", if(name == "\"\"", do: :not_a_string, else: :invalid_name)}],
               name
      end

      assert {:ok, _, _} =
               validate(
                 target(
                   "{ name: #{String.duplicate("a", 63)}, host: h, probes: [{ name: a.b_c-1, protocol: icmp }] }"
                 )
               )
    end

    test "hosts are IP addresses or host names" do
      for host <- ["192.0.2.1", "\"2001:db8::1\"", "router", "sw-1.example.net.", "_dns.example"] do
        assert {:ok, _, _} =
                 validate(
                   target("{ name: t, host: #{host}, probes: [{ name: a, protocol: icmp }] }")
                 ),
               host
      end

      for host <- ["192.0.2.300", "1.2.3", "-a.example", "a..b", "\"fe80::1%eth0\""] do
        assert errors(target("{ name: t, host: #{host}, probes: [{ name: a, protocol: icmp }] }")) ==
                 [{"targets[0].host", :invalid_host}],
               host
      end
    end

    test "family must match an address literal" do
      yaml =
        target(
          "{ name: t, host: 192.0.2.1, family: ipv6, probes: [{ name: a, protocol: icmp }] }"
        )

      assert errors(yaml) == [{"targets[0].family", :family_mismatch}]

      yaml =
        target("{ name: t, host: \"::1\", family: ipv4, probes: [{ name: a, protocol: icmp }] }")

      assert errors(yaml) == [{"targets[0].family", :family_mismatch}]
    end

    test "ports are 1 to 65535" do
      assert errors(
               probe(
                 "{ name: a, protocol: tcp, port: 0 }, { name: b, protocol: tcp, port: 65536 }, { name: c, protocol: tcp, port: \"22\" }"
               )
             ) ==
               [
                 {"targets[0].probes[0].port", :invalid_port},
                 {"targets[0].probes[1].port", :invalid_port},
                 {"targets[0].probes[2].port", :invalid_port}
               ]
    end

    test "OIDs are numeric strings" do
      assert {:ok, _, _} =
               validate(
                 probe("{ name: a, protocol: snmp, oids: [\"0.0\", \"2.999.4294967295\"] }")
               )

      for oid <- [
            "\"1\"",
            "\"3.1\"",
            "\"1.03\"",
            "\".1.3\"",
            "\"1.3.\"",
            "\"1.3.4294967296\"",
            "iso.3"
          ] do
        assert errors(probe("{ name: a, protocol: snmp, oids: [#{oid}] }")) ==
                 [{"targets[0].probes[0].oids[0]", :invalid_oid}],
               oid
      end
    end

    test "timeout must be shorter than interval" do
      assert errors(probe("{ name: a, protocol: icmp, interval: 1s, timeout: 1000ms }")) ==
               [{"targets[0].probes[0].timeout", :timeout_too_long}]

      # A timeout from defaults is checked as well.
      assert errors(
               "defaults: { snmp_timeout: 2m }\n" <>
                 probe("{ name: a, protocol: snmp, oids: [\"1.3\"] }")
             ) ==
               [{"targets[0].probes[0].timeout", :timeout_too_long}]
    end
  end

  describe "lists and names" do
    test "targets, probes and oids must not be empty" do
      assert errors("targets: []\n") == [{"targets", :empty_list}]

      assert errors(target("{ name: t, host: h, probes: [] }")) == [
               {"targets[0].probes", :empty_list}
             ]

      assert errors(probe("{ name: a, protocol: snmp, oids: [] }")) == [
               {"targets[0].probes[0].oids", :empty_list}
             ]
    end

    test "target names and probe names within a target must be unique" do
      yaml = """
      targets:
        - { name: t, host: h, probes: [{ name: a, protocol: icmp }, { name: a, protocol: icmp }] }
        - { name: t, host: h, probes: [{ name: a, protocol: icmp }] }
      """

      assert {:error, issues} = validate(yaml)

      assert Enum.map(issues, &{Issue.format_path(&1.path), &1.reason, &1.detail}) == [
               {"targets[0].probes[1].name", :duplicate_name, [line: 2]},
               {"targets[1].name", :duplicate_name, [line: 2]}
             ]
    end
  end

  describe "SNMP settings and credentials" do
    test "SNMP probes need the target's snmp settings" do
      yaml =
        target("{ name: t, host: h, probes: [{ name: a, protocol: snmp, oids: [\"1.3\"] }] }")

      assert errors(yaml) == [{"targets[0]", :snmp_missing}]
    end

    test "a credential reference must exist" do
      yaml =
        "targets:\n  - { name: t, host: h, snmp: { credential: nope }, probes: [{ name: a, protocol: icmp }] }\n"

      assert errors(yaml) == [{"targets[0].snmp.credential", :unknown_credential}]
    end

    test "a broken profile is reported once, not again where it is used" do
      yaml = """
      credentials: { c: { version: v2c } }
      targets:
        - { name: t, host: h, snmp: { credential: c }, probes: [{ name: a, protocol: icmp }] }
      """

      assert errors(yaml) == [{"credentials.c", :missing_key}]
    end

    test "v3 is not supported yet, and its keys are not reported as unknown" do
      yaml = """
      credentials: { c: { version: v3, user: u, auth: sha256, auth_pass: p } }
      targets:
        - { name: t, host: h, probes: [{ name: a, protocol: icmp }] }
      """

      assert errors(yaml) == [{"credentials.c.version", :unsupported_version}]
    end

    test "profile names follow the name rule" do
      yaml = """
      credentials: { Bad: { version: v2c, community: x } }
      targets:
        - { name: t, host: h, probes: [{ name: a, protocol: icmp }] }
      """

      assert errors(yaml) == [{"credentials", :invalid_name}]
    end
  end

  describe "warnings" do
    test "an NTP probe with an interval under 8s is a warning, not an error" do
      assert {:ok, _config, [warning]} =
               validate(probe("{ name: a, protocol: udp, service: ntp, interval: 7s }"))

      assert %Issue{severity: :warning, reason: :ntp_interval_short} = warning
      assert Issue.format_path(warning.path) == "targets[0].probes[0].interval"

      assert {:ok, _, []} =
               validate(probe("{ name: a, protocol: udp, service: ntp, interval: 8s }"))

      assert {:ok, _, []} =
               validate(
                 probe("{ name: a, protocol: udp, service: dns, interval: 1s, timeout: 500ms }")
               )
    end

    test "the warning also comes from a short default interval" do
      yaml = "defaults: { interval: 5s }\n" <> probe("{ name: a, protocol: udp, service: ntp }")
      assert {:ok, _, [%Issue{reason: :ntp_interval_short}]} = validate(yaml)
    end
  end

  test "the root must be a mapping" do
    assert errors("- a\n") == [{"", :not_a_map}]
    assert errors("just text\n") == [{"", :not_a_map}]
  end

  test "errors keep going past the first one and come in file order" do
    yaml = """
    compression: xz
    targets:
      - { name: T, host: h, probes: [{ name: a, protocol: icmp, timeout: 1 }] }
    retention_days: -1
    """

    assert errors(yaml) == [
             {"compression", :invalid_value},
             {"targets[0].name", :invalid_name},
             {"targets[0].probes[0].timeout", :invalid_duration},
             {"retention_days", :invalid_integer}
           ]
  end
end
