defmodule Detchi.Config.Credential do
  @moduledoc """
  A named SNMP credential profile (docs/basic-design.md, 7.8).

  `inspect/2` hides the secret, in case a credential ends up in a log
  line or an exception.
  """

  @enforce_keys [:name, :version, :community]
  defstruct [:name, :version, :community]

  @type t :: %__MODULE__{name: String.t(), version: :v2c, community: String.t()}

  defimpl Inspect do
    def inspect(credential, _opts) do
      "#Detchi.Config.Credential<#{credential.name}, #{credential.version}, community: [redacted]>"
    end
  end
end
