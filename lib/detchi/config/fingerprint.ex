defmodule Detchi.Config.Fingerprint do
  @moduledoc """
  The config fingerprint of a target, written as `config_hash` in the
  `start` and `file_opened` lines (docs/basic-design.md, 7.9).

  The input is the target's definition with defaults filled in, as
  canonical JSON: keys sorted, no whitespace, durations in milliseconds
  (`interval_ms`, `timeout_ms`), probes sorted by name, OIDs in their
  order, and keys whose value is `nil` left out. Credentials and the
  name of the credential profile are left out, so the input holds no
  secret; only the SNMP version of the profile is kept.
  """

  alias Detchi.Config.{Probe, Target}

  @doc ~S"""
  The fingerprint: `"sha256:"` and 64 lower-case hex digits.
  """
  @spec hash(Target.t()) :: String.t()
  def hash(%Target{} = target) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, canonical(target)), case: :lower)
  end

  @doc "The canonical JSON the fingerprint is taken of."
  @spec canonical(Target.t()) :: String.t()
  def canonical(%Target{} = target) do
    [
      name: target.name,
      host: target.host,
      family: target.family,
      snmp: snmp(target.snmp),
      probes: target.probes |> Enum.sort_by(& &1.name) |> Enum.map(&probe/1)
    ]
    |> object()
    |> encode()
    |> IO.iodata_to_binary()
  end

  defp snmp(nil), do: nil

  defp snmp(%{credential: credential, port: port}),
    do: object(version: credential.version, port: port)

  defp probe(%Probe{} = probe) do
    object(
      name: probe.name,
      protocol: probe.protocol,
      interval_ms: probe.interval_ms,
      timeout_ms: probe.timeout_ms,
      port: probe.port,
      service: probe.service,
      oids: probe.oids && Enum.map(probe.oids, &Enum.join(&1, "."))
    )
  end

  # Keys are sorted as strings, so the order does not depend on how
  # json:encode/1 walks a map.
  defp object(pairs) do
    pairs
    |> Enum.reject(fn {_, value} -> is_nil(value) end)
    |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Enum.sort()
    |> then(&{:object, &1})
  end

  defp encode(value), do: :json.encode(value, &encode_value/2)

  defp encode_value({:object, pairs}, encode), do: :json.encode_key_value_list(pairs, encode)
  defp encode_value(value, encode), do: :json.encode_value(value, encode)
end
