defmodule Detchi.Record do
  @moduledoc """
  Encodes record lines: JSON Lines in the schema of docs/basic-design.md, 6.1.

  A record is a map. A measurement has `:protocol` and an event has
  `:event`. Keys come out in a fixed order: `v`, `ts`, `target`, then the
  keys of the line in the order of the schema, with protocol-specific
  objects last. Keys whose value is `nil` are left out, so a target whose
  host name has never resolved can pass `addr: nil`.

  Values are given as Detchi holds them, and converted here:

    * `ts`, `first_ts`, `last_ts`: system time in microseconds, written
      as RFC 3339 in local time with a numeric offset.
    * `addr`, `old`, `new` and the `from` of an ICMP error: IP address
      tuples, written in dotted form or in RFC 5952 form.
    * `error`: `{:errno, errno}`, `{:icmp, type, code, from}`,
      `{:snmp, error_status, error_index}`, `{:snmp_report, oid}`,
      `{:resolve, errno}` or `:internal`.
    * `snmp.varbinds`: `{oid, type, value}` as `snmpm` returns them.
  """

  @schema_version 1

  @measurement_keys [:probe, :protocol, :addr, :port, :status, :rtt_us, :timeout_ms, :error] ++
                      [:udp, :snmp]

  @event_keys %{
    start: [:version, :config_hash, :addr],
    file_opened: [:version, :config_hash, :addr],
    stop: [:abandoned],
    dropped: [:count, :first_ts, :last_ts],
    resolve_failed: [:host, :error, :addr],
    addr_changed: [:host, :old, :new],
    clock_stepped: [:offset_us]
  }

  @type error ::
          {:errno, atom()}
          | {:icmp, non_neg_integer(), non_neg_integer(), :inet.ip_address()}
          | {:snmp, atom(), non_neg_integer()}
          | {:snmp_report, [non_neg_integer()]}
          | {:resolve, atom()}
          | :internal

  @doc """
  Encodes a record as one line, ending with a newline.

  `offset` is passed to `:calendar.system_time_to_rfc3339/2`; it defaults
  to local time, which follows `TZ`. Tests give a fixed one, because the
  VM reads `TZ` only once.
  """
  @spec encode(map(), keyword()) :: iodata()
  def encode(record, opts \\ []) do
    offset = Keyword.get(opts, :offset, ~c"")

    keys =
      case record do
        %{protocol: _} ->
          @measurement_keys

        %{event: event} ->
          [:event | Map.get(@event_keys, event) || raise(ArgumentError, "unknown event #{event}")]
      end

    case Map.keys(record) -- [:ts, :target | keys] do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown keys #{inspect(unknown)}"
    end

    pairs =
      Enum.flat_map([:ts, :target | keys], fn key ->
        case Map.get(record, key) do
          nil -> []
          value -> [{key, value(key, value, offset)}]
        end
      end)

    [encode_object([{:v, @schema_version} | pairs]), ?\n]
  end

  @doc """
  Formats system time in microseconds as RFC 3339 with six fractional
  digits and a numeric offset, such as `2026-10-23T21:00:00.123456+09:00`.
  """
  @spec format_ts(integer(), keyword()) :: String.t()
  def format_ts(us, opts \\ []) do
    us
    |> :calendar.system_time_to_rfc3339(
      unit: :microsecond,
      offset: Keyword.get(opts, :offset, ~c"")
    )
    |> List.to_string()
  end

  @doc """
  Formats an IP address: IPv4 in dotted form, IPv6 in the form of
  RFC 5952 (lower case, the longest run of zero groups shortened).
  Only IPv4-mapped addresses keep the dotted tail, as RFC 5952, 5 suggests.
  """
  @spec format_addr(:inet.ip_address()) :: String.t()
  def format_addr({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> List.to_string()
  def format_addr({0, 0, 0, 0, 0, 0xFFFF, _, _} = ip), do: ip |> :inet.ntoa() |> List.to_string()

  def format_addr({_, _, _, _, _, _, _, _} = ip) do
    groups = Tuple.to_list(ip)

    case longest_zero_run(groups) do
      {_, length} when length < 2 ->
        join_groups(groups)

      {start, length} ->
        {head, rest} = Enum.split(groups, start)
        join_groups(head) <> "::" <> join_groups(Enum.drop(rest, length))
    end
  end

  # The first of the longest runs wins a tie (RFC 5952, 4.2.3).
  defp longest_zero_run(groups) do
    groups
    |> Enum.with_index()
    |> Enum.chunk_by(fn {group, _} -> group == 0 end)
    |> Enum.reduce({0, 0}, fn
      [{0, start} | _] = run, {_, longest} when length(run) > longest -> {start, length(run)}
      _, acc -> acc
    end)
  end

  defp join_groups(groups),
    do: Enum.map_join(groups, ":", &String.downcase(Integer.to_string(&1, 16)))

  defp value(key, us, offset) when key in [:ts, :first_ts, :last_ts],
    do: format_ts(us, offset: offset)

  defp value(key, ip, _) when key in [:addr, :old, :new], do: format_addr(ip)
  defp value(:error, error, _), do: {:object, error_pairs(error)}
  defp value(:udp, %{service: service}, _), do: {:object, [service: service]}

  # Lines without a reply, or with an errorStatus, have no varbinds.
  defp value(:snmp, %{version: version, op: op} = snmp, _) do
    case snmp do
      %{varbinds: varbinds} ->
        varbinds = Enum.map(varbinds, &{:object, varbind_pairs(&1)})
        {:object, [version: version, op: op, varbinds: varbinds]}

      _ ->
        {:object, [version: version, op: op]}
    end
  end

  defp value(_, value, _) when is_atom(value) or is_binary(value) or is_integer(value),
    do: value

  defp error_pairs({:errno, errno}), do: [reason: :errno, errno: errno]

  defp error_pairs({:icmp, type, code, from}),
    do: [reason: :icmp, type: type, code: code, from: format_addr(from)]

  defp error_pairs({:snmp, status, index}),
    do: [reason: :snmp, error_status: status, error_index: index]

  defp error_pairs({:snmp_report, oid}), do: [reason: :snmp_report, oid: format_oid(oid)]
  defp error_pairs({:resolve, errno}), do: [reason: :resolve, errno: errno]
  defp error_pairs(:internal), do: [reason: :internal]

  # Types are those snmpm decodes from the BER tags (snmp_pdus:dec_value/1);
  # Gauge32 shares its tag with Unsigned32.
  defp varbind_pairs({oid, type, value}) do
    [{:oid, format_oid(oid)} | typed_value(type, value)]
  end

  defp typed_value(:INTEGER, n), do: [type: "Integer", value: n]
  defp typed_value(:Counter32, n), do: [type: "Counter32", value: n]
  defp typed_value(:Unsigned32, n), do: [type: "Gauge32", value: n]
  defp typed_value(:TimeTicks, n), do: [type: "TimeTicks", value: n]
  defp typed_value(:Counter64, n), do: [type: "Counter64", value: n]

  defp typed_value(:"OBJECT IDENTIFIER", oid),
    do: [type: "ObjectIdentifier", value: format_oid(oid)]

  defp typed_value(:IpAddress, [_, _, _, _] = ip),
    do: [type: "IpAddress", value: format_addr(List.to_tuple(ip))]

  defp typed_value(:IpAddress, bytes), do: [type: "IpAddress", hex: hex(bytes)]
  defp typed_value(:Opaque, bytes), do: [type: "Opaque", hex: hex(bytes)]
  defp typed_value(:NULL, :NULL), do: [type: "Null"]

  defp typed_value(:NULL, exception)
       when exception in [:noSuchObject, :noSuchInstance, :endOfMibView],
       do: [type: Atom.to_string(exception)]

  defp typed_value(:"OCTET STRING", bytes) do
    binary = :erlang.list_to_binary(bytes)

    if text?(binary),
      do: [type: "OctetString", value: binary],
      else: [type: "OctetString", hex: hex(binary)]
  end

  # Text is valid UTF-8 without control characters (C0, DEL and C1) other
  # than tab, newline and carriage return (docs/basic-design.md, 6.1).
  defp text?(binary),
    do:
      String.valid?(binary) and
        not Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]/u, binary)

  defp hex(bytes), do: bytes |> IO.iodata_to_binary() |> Base.encode16(case: :lower)

  defp format_oid(oid), do: Enum.join(oid, ".")

  # json:encode/1 does not keep the order of map keys, so objects are kept
  # as key-value lists (docs/basic-design.md, 6.1).
  defp encode_object(pairs), do: :json.encode_key_value_list(pairs, &encode_value/2)

  defp encode_value({:object, pairs}, _encode), do: encode_object(pairs)
  defp encode_value(value, encode), do: :json.encode_value(value, encode)
end
