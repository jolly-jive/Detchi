defmodule Detchi.Config.Credential do
  @moduledoc """
  A named SNMP credential profile (docs/basic-design.md, 7.8).

  A v2c profile has `community`. A v3 profile has `user`, and `auth` and
  `auth_pass` for authNoPriv, plus `priv` and `priv_pass` for authPriv;
  without `auth` it is noAuthNoPriv.

  `inspect/2` hides the secrets, and the v3 user name with them, in case
  a credential ends up in a log line or an exception.
  """

  @enforce_keys [:name, :version]
  defstruct [:name, :version, :community, :user, :auth, :auth_pass, :priv, :priv_pass]

  @type auth :: :md5 | :sha | :sha224 | :sha256 | :sha384 | :sha512
  @type priv :: :des | :aes128

  @type t :: %__MODULE__{
          name: String.t(),
          version: :v2c | :v3,
          community: String.t() | nil,
          user: String.t() | nil,
          auth: auth() | nil,
          auth_pass: String.t() | nil,
          priv: priv() | nil,
          priv_pass: String.t() | nil
        }

  @doc "The security level of a v3 profile."
  @spec sec_level(t()) :: :noAuthNoPriv | :authNoPriv | :authPriv
  def sec_level(%__MODULE__{version: :v3, auth: nil}), do: :noAuthNoPriv
  def sec_level(%__MODULE__{version: :v3, priv: nil}), do: :authNoPriv
  def sec_level(%__MODULE__{version: :v3}), do: :authPriv

  defimpl Inspect do
    def inspect(%{version: :v2c} = credential, _opts),
      do: "#Detchi.Config.Credential<#{credential.name}, v2c, community: [redacted]>"

    def inspect(credential, _opts) do
      "#Detchi.Config.Credential<#{credential.name}, v3, " <>
        "#{Detchi.Config.Credential.sec_level(credential)}, [redacted]>"
    end
  end
end
