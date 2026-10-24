defmodule Detchi.Config.Target do
  @moduledoc """
  A target (a device) and its probes, with defaults filled in.

  `address` is set when `host` is an IP address; a host name is resolved
  later (docs/basic-design.md, 7.6).
  """

  alias Detchi.Config.{Credential, Probe}

  @enforce_keys [:name, :host, :family, :probes]
  defstruct [:name, :host, :address, :family, :snmp, :probes]

  @type snmp :: %{credential: Credential.t(), port: :inet.port_number()}

  @type t :: %__MODULE__{
          name: String.t(),
          host: String.t(),
          address: :inet.ip_address() | nil,
          family: :ipv4 | :ipv6 | :auto,
          snmp: snmp() | nil,
          probes: [Probe.t()]
        }
end
