defmodule Detchi.RecordTest do
  use ExUnit.Case, async: true

  alias Detchi.Record

  defp ts(text),
    do: :calendar.rfc3339_to_system_time(String.to_charlist(text), unit: :microsecond)

  defp encode(record), do: record |> Record.encode(offset: ~c"+09:00") |> IO.iodata_to_binary()

  defp snmp_line(varbinds) do
    %{
      ts: ts("2026-10-23T21:00:00.140000+09:00"),
      target: "core1",
      probe: "if-uplink",
      protocol: :snmp,
      addr: {192, 0, 2, 1},
      status: :ok,
      rtt_us: 5678,
      snmp: %{version: :v2c, op: :get, varbinds: varbinds}
    }
    |> encode()
    |> :json.decode()
    |> get_in(["snmp", "varbinds"])
  end

  describe "measurement lines" do
    # The examples of docs/basic-design.md, 6.1.
    test "match the examples of the schema" do
      assert encode(%{
               ts: ts("2026-10-23T21:00:00.123456+09:00"),
               target: "core1",
               probe: "ping",
               protocol: :icmp,
               addr: {192, 0, 2, 1},
               status: :ok,
               rtt_us: 1234
             }) ==
               ~s({"v":1,"ts":"2026-10-23T21:00:00.123456+09:00","target":"core1","probe":"ping","protocol":"icmp","addr":"192.0.2.1","status":"ok","rtt_us":1234}\n)

      assert encode(%{
               ts: ts("2026-10-23T21:01:00.120001+09:00"),
               target: "core1",
               probe: "ping",
               protocol: :icmp,
               addr: {192, 0, 2, 1},
               status: :timeout,
               timeout_ms: 1000
             }) ==
               ~s({"v":1,"ts":"2026-10-23T21:01:00.120001+09:00","target":"core1","probe":"ping","protocol":"icmp","addr":"192.0.2.1","status":"timeout","timeout_ms":1000}\n)

      assert encode(%{
               ts: ts("2026-10-23T21:00:00.130000+09:00"),
               target: "core1",
               probe: "dns",
               protocol: :udp,
               addr: {192, 0, 2, 1},
               port: 53,
               status: :ok,
               rtt_us: 2345,
               udp: %{service: :dns}
             }) ==
               ~s({"v":1,"ts":"2026-10-23T21:00:00.130000+09:00","target":"core1","probe":"dns","protocol":"udp","addr":"192.0.2.1","port":53,"status":"ok","rtt_us":2345,"udp":{"service":"dns"}}\n)

      assert encode(%{
               ts: ts("2026-10-23T21:00:00.135000+09:00"),
               target: "core1",
               probe: "ssh",
               protocol: :tcp,
               addr: {192, 0, 2, 1},
               port: 22,
               status: :refused,
               rtt_us: 456,
               error: {:errno, :econnrefused}
             }) ==
               ~s({"v":1,"ts":"2026-10-23T21:00:00.135000+09:00","target":"core1","probe":"ssh","protocol":"tcp","addr":"192.0.2.1","port":22,"status":"refused","rtt_us":456,"error":{"reason":"errno","errno":"econnrefused"}}\n)

      assert encode(%{
               ts: ts("2026-10-23T21:00:00.140000+09:00"),
               target: "core1",
               probe: "if-uplink",
               protocol: :snmp,
               addr: {192, 0, 2, 1},
               status: :ok,
               rtt_us: 5678,
               snmp: %{
                 version: :v2c,
                 op: :get,
                 varbinds: [
                   {[1, 3, 6, 1, 2, 1, 1, 3, 0], :TimeTicks, 123_456},
                   {[1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 1, 1], :"OCTET STRING", ~c"Gi0/1"},
                   {[1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 6, 1], :Counter64, 18_446_744_073_709_551_615}
                 ]
               }
             }) ==
               ~s({"v":1,"ts":"2026-10-23T21:00:00.140000+09:00","target":"core1","probe":"if-uplink","protocol":"snmp","addr":"192.0.2.1","status":"ok","rtt_us":5678,) <>
                 ~s("snmp":{"version":"v2c","op":"get","varbinds":[) <>
                 ~s({"oid":"1.3.6.1.2.1.1.3.0","type":"TimeTicks","value":123456},) <>
                 ~s({"oid":"1.3.6.1.2.1.31.1.1.1.1.1","type":"OctetString","value":"Gi0/1"},) <>
                 ~s({"oid":"1.3.6.1.2.1.31.1.1.1.6.1","type":"Counter64","value":18446744073709551615}]}}\n)
    end

    test "leave out addr when the host name has never resolved" do
      assert encode(%{
               ts: ts("2026-10-23T21:00:00.000000+09:00"),
               target: "core1",
               probe: "ping",
               protocol: :icmp,
               addr: nil,
               status: :error,
               error: {:resolve, :nxdomain}
             }) ==
               ~s({"v":1,"ts":"2026-10-23T21:00:00.000000+09:00","target":"core1","probe":"ping","protocol":"icmp","status":"error","error":{"reason":"resolve","errno":"nxdomain"}}\n)
    end
  end

  test "error objects" do
    error = fn error ->
      %{ts: 0, target: "t", probe: "p", protocol: :icmp, status: :error, error: error}
      |> encode()
      |> :json.decode()
      |> Map.fetch!("error")
    end

    assert error.({:icmp, 11, 0, {192, 0, 2, 254}}) ==
             %{"reason" => "icmp", "type" => 11, "code" => 0, "from" => "192.0.2.254"}

    assert error.({:icmp, 1, 4, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}})["from"] == "2001:db8::1"

    assert error.({:snmp, :genErr, 2}) ==
             %{"reason" => "snmp", "error_status" => "genErr", "error_index" => 2}

    assert error.({:snmp_report, [1, 3, 6, 1, 6, 3, 15, 1, 1, 5, 0]}) ==
             %{"reason" => "snmp_report", "oid" => "1.3.6.1.6.3.15.1.1.5.0"}

    assert error.(:internal) == %{"reason" => "internal"}

    # Key order inside the object follows the schema too.
    assert %{ts: 0, target: "t", probe: "p", protocol: :icmp, status: :unreachable}
           |> Map.put(:error, {:icmp, 3, 1, {192, 0, 2, 254}})
           |> encode() =~ ~s("error":{"reason":"icmp","type":3,"code":1,"from":"192.0.2.254"})
  end

  describe "SNMP values" do
    test "each type that snmpm returns" do
      assert snmp_line([
               {[1, 1], :INTEGER, -5},
               {[1, 2], :Counter32, 4_294_967_295},
               {[1, 3], :Unsigned32, 7},
               {[1, 4], :"OBJECT IDENTIFIER", [1, 3, 6, 1, 2, 1, 2, 2, 1, 1]},
               {[1, 5], :IpAddress, [192, 0, 2, 1]},
               {[1, 6], :Opaque, [0x9F, 0x78, 0x04]},
               {[1, 7], :NULL, :noSuchObject},
               {[1, 8], :NULL, :noSuchInstance},
               {[1, 9], :NULL, :endOfMibView},
               {[1, 10], :NULL, :NULL}
             ]) == [
               %{"oid" => "1.1", "type" => "Integer", "value" => -5},
               %{"oid" => "1.2", "type" => "Counter32", "value" => 4_294_967_295},
               %{"oid" => "1.3", "type" => "Gauge32", "value" => 7},
               %{"oid" => "1.4", "type" => "ObjectIdentifier", "value" => "1.3.6.1.2.1.2.2.1.1"},
               %{"oid" => "1.5", "type" => "IpAddress", "value" => "192.0.2.1"},
               %{"oid" => "1.6", "type" => "Opaque", "hex" => "9f7804"},
               %{"oid" => "1.7", "type" => "noSuchObject"},
               %{"oid" => "1.8", "type" => "noSuchInstance"},
               %{"oid" => "1.9", "type" => "endOfMibView"},
               %{"oid" => "1.10", "type" => "Null"}
             ]
    end

    test "an IpAddress that is not 4 bytes long goes to hex" do
      assert snmp_line([{[1], :IpAddress, [192, 0, 2]}]) ==
               [%{"oid" => "1", "type" => "IpAddress", "hex" => "c00002"}]
    end

    test "an OctetString is text when it is UTF-8 without control characters but tab, LF and CR" do
      for text <- ["Gi0/1", "", "Cisco IOS\r\nVersion 15.2\tfoo", "東京-core1"] do
        assert snmp_line([{[1], :"OCTET STRING", String.to_charlist(text) |> to_bytes()}]) ==
                 [%{"oid" => "1", "type" => "OctetString", "value" => text}],
               inspect(text)
      end
    end

    test "other OctetStrings go to hex" do
      for {bytes, hex} <- [
            {[0x00, 0x11, 0x22, 0xAA, 0xBB, 0xCC], "001122aabbcc"},
            {~c"eth0" ++ [0], "6574683000"},
            {[?a, 0x7F], "617f"},
            {[?a, 0x1B], "611b"},
            # U+0085 (NEL), a C1 control character, in UTF-8.
            {[?a, 0xC2, 0x85], "61c285"},
            # Not UTF-8.
            {[0xFF, 0xFE], "fffe"}
          ] do
        assert snmp_line([{[1], :"OCTET STRING", bytes}]) ==
                 [%{"oid" => "1", "type" => "OctetString", "hex" => hex}],
               hex
      end
    end
  end

  # snmpm returns OCTET STRING values as lists of bytes.
  defp to_bytes(chars), do: chars |> List.to_string() |> :binary.bin_to_list()

  describe "event lines" do
    test "start, as in the example of the schema" do
      assert encode(%{
               ts: ts("2026-10-23T21:00:00.000000+09:00"),
               target: "core1",
               event: :start,
               version: "0.1.0",
               config_hash: "sha256:3f9a",
               addr: {192, 0, 2, 1}
             }) ==
               ~s({"v":1,"ts":"2026-10-23T21:00:00.000000+09:00","target":"core1","event":"start","version":"0.1.0","config_hash":"sha256:3f9a","addr":"192.0.2.1"}\n)
    end

    test "each event, with its keys in order" do
      line = fn record -> encode(Map.merge(%{ts: 0, target: "core1"}, record)) end
      prefix = ~s({"v":1,"ts":"1970-01-01T09:00:00.000000+09:00","target":"core1",)

      assert line.(%{event: :file_opened, version: "0.1.0", config_hash: "sha256:00"}) ==
               prefix <> ~s("event":"file_opened","version":"0.1.0","config_hash":"sha256:00"}\n)

      assert line.(%{event: :stop, abandoned: 3}) ==
               prefix <> ~s("event":"stop","abandoned":3}\n)

      assert line.(%{event: :dropped, count: 2, first_ts: 1_000_000, last_ts: 2_500_000}) ==
               prefix <>
                 ~s("event":"dropped","count":2,"first_ts":"1970-01-01T09:00:01.000000+09:00","last_ts":"1970-01-01T09:00:02.500000+09:00"}\n)

      assert line.(%{
               event: :resolve_failed,
               host: "core1.example.net",
               error: {:resolve, :nxdomain},
               addr: {192, 0, 2, 1}
             }) ==
               prefix <>
                 ~s("event":"resolve_failed","host":"core1.example.net","error":{"reason":"resolve","errno":"nxdomain"},"addr":"192.0.2.1"}\n)

      assert line.(%{
               event: :addr_changed,
               host: "core1.example.net",
               old: {192, 0, 2, 1},
               new: {192, 0, 2, 2}
             }) ==
               prefix <>
                 ~s("event":"addr_changed","host":"core1.example.net","old":"192.0.2.1","new":"192.0.2.2"}\n)

      assert line.(%{event: :addr_changed, host: "core1.example.net", new: {192, 0, 2, 2}}) ==
               prefix <>
                 ~s("event":"addr_changed","host":"core1.example.net","new":"192.0.2.2"}\n)

      assert line.(%{event: :clock_stepped, offset_us: -1_500_000}) ==
               prefix <> ~s("event":"clock_stepped","offset_us":-1500000}\n)
    end
  end

  test "unknown keys and events are programming errors" do
    assert_raise ArgumentError, fn ->
      encode(%{ts: 0, target: "t", probe: "p", protocol: :icmp, status: :ok, rtt: 1})
    end

    assert_raise ArgumentError, fn -> encode(%{ts: 0, target: "t", event: :bogus}) end
    assert_raise ArgumentError, fn -> encode(%{ts: 0, target: "t", event: :stop, count: 1}) end
  end

  describe "format_ts/2" do
    test "writes six fractional digits and a numeric offset, even for UTC" do
      assert Record.format_ts(ts("2026-10-23T12:00:00Z"), offset: ~c"+00:00") ==
               "2026-10-23T12:00:00.000000+00:00"

      assert Record.format_ts(ts("2026-10-23T12:00:00.000001Z"), offset: ~c"-05:00") ==
               "2026-10-23T07:00:00.000001-05:00"
    end

    test "uses local time by default" do
      assert Record.format_ts(0) =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.000000[+-]\d\d:\d\d\z/
    end
  end

  describe "format_addr/1" do
    test "IPv4" do
      assert Record.format_addr({192, 0, 2, 1}) == "192.0.2.1"
    end

    test "IPv6 in the form of RFC 5952" do
      for {ip, text} <- [
            {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, "2001:db8::1"},
            {{0x2001, 0xDB8, 0, 0, 0, 0, 0xAB, 0xCD}, "2001:db8::ab:cd"},
            {{0x2001, 0xDB8, 0xABCD, 0x12, 0, 0, 0, 1}, "2001:db8:abcd:12::1"},
            # A single zero group is not shortened (4.2.2).
            {{0x2001, 0xDB8, 0, 1, 1, 1, 1, 1}, "2001:db8:0:1:1:1:1:1"},
            # The longest run wins (4.2.3), and the first of equal runs.
            {{0x2001, 0, 0, 1, 0, 0, 0, 1}, "2001:0:0:1::1"},
            {{0x2001, 0xDB8, 0, 0, 1, 0, 0, 1}, "2001:db8::1:0:0:1"},
            {{0, 0, 0, 0, 0, 0, 0, 0}, "::"},
            {{0, 0, 0, 0, 0, 0, 0, 1}, "::1"},
            {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, "fe80::"},
            # IPv4-mapped keeps the dotted tail (5); deprecated IPv4-compatible does not.
            {{0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x0201}, "::ffff:192.0.2.1"},
            {{0, 0, 0, 0, 0, 0, 0xC000, 0x0201}, "::c000:201"},
            {{0, 0, 0, 0, 0, 0, 0, 2}, "::2"}
          ] do
        assert Record.format_addr(ip) == text
      end
    end
  end
end
