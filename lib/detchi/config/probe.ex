defmodule Detchi.Config.Probe do
  @moduledoc """
  One probe of a target, with defaults filled in.

  The fields after `timeout_ms` depend on `protocol`: `port` for tcp and
  udp, `service` for udp, `oids` for snmp. The others are nil.
  """

  @enforce_keys [:name, :protocol, :interval_ms, :timeout_ms]
  defstruct [:name, :protocol, :interval_ms, :timeout_ms, :port, :service, :oids]

  @type t :: %__MODULE__{
          name: String.t(),
          protocol: :icmp | :tcp | :udp | :snmp,
          interval_ms: pos_integer(),
          timeout_ms: pos_integer(),
          port: :inet.port_number() | nil,
          service: :dns | :ntp | :quic | nil,
          oids: [[non_neg_integer()]] | nil
        }
end
