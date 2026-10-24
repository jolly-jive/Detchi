defmodule Detchi.Config.Issue do
  @moduledoc """
  An error or a warning about the config file.

  An issue never holds text from the file (docs/basic-design.md, 7.1):
  `path` is made of schema keys, list indices and names that passed the
  name rule, and `detail` holds only atoms and numbers chosen by Detchi.
  """

  @enforce_keys [:reason]
  defstruct severity: :error, path: [], line: nil, column: nil, reason: nil, detail: []

  @type t :: %__MODULE__{
          severity: :error | :warning,
          path: [String.t() | non_neg_integer()],
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          reason: atom(),
          detail: keyword()
        }

  @doc "Formats an issue in the style of compiler messages: `file:line:column: ...`."
  @spec format(t(), Path.t()) :: String.t()
  def format(%__MODULE__{} = issue, file) do
    location =
      case issue do
        %{line: nil} -> file
        %{line: line, column: column} -> "#{file}:#{line}:#{column}"
      end

    subject =
      case format_path(issue.path) do
        "" -> ""
        path -> path <> ": "
      end

    "#{location}: #{issue.severity}: #{subject}#{message(issue.reason, issue.detail)}"
  end

  @doc false
  def format_path(path) do
    Enum.reduce(path, "", fn
      index, acc when is_integer(index) -> "#{acc}[#{index}]"
      key, "" -> key
      key, acc -> "#{acc}.#{key}"
    end)
  end

  defp message(:file_error, detail), do: "cannot read the file (#{detail[:errno]})"
  defp message(:empty_document, _), do: "the file holds no YAML document"
  defp message(:multiple_documents, _), do: "the file must hold a single YAML document"
  defp message(:yaml_syntax, detail), do: "YAML syntax error (#{detail[:type]})"

  defp message(:flow_anchor, _),
    do:
      "an anchor on a [...] or {...} collection is not supported; write the collection in block style"

  defp message(:unknown_key, _), do: "unknown key"
  defp message(:duplicate_key, _), do: "duplicate key"
  defp message(:missing_key, detail), do: "missing key \"#{detail[:key]}\""
  defp message(:not_a_map, _), do: "must be a mapping"
  defp message(:not_a_list, _), do: "must be a list"
  defp message(:empty_list, _), do: "must not be empty"
  defp message(:not_a_string, _), do: "must be a non-empty string"
  defp message(:invalid_name, _), do: "must match ^[a-z0-9][a-z0-9._-]{0,62}$"

  defp message(:duplicate_name, detail),
    do: "duplicate name (first used on line #{detail[:line]})"

  defp message(:invalid_duration, _),
    do: "must be a positive duration with a unit (ms, s, m, h), such as \"60s\""

  defp message(:invalid_integer, _), do: "must be a positive integer"
  defp message(:invalid_port, _), do: "must be an integer from 1 to 65535"
  defp message(:invalid_value, detail), do: "must be one of: #{Enum.join(detail[:allowed], ", ")}"
  defp message(:invalid_path, _), do: "must be an absolute path"
  defp message(:invalid_host, _), do: "must be an IP address or a host name"
  defp message(:invalid_oid, _), do: "must be a numeric OID string, such as \"1.3.6.1.2.1.1.3.0\""
  defp message(:unsupported_version, _), do: "SNMPv3 is not supported yet"
  defp message(:unknown_credential, _), do: "no such credential"
  defp message(:family_mismatch, _), do: "does not match the address family of host"
  defp message(:snmp_missing, _), do: "SNMP probes need the snmp settings of the target"
  defp message(:timeout_too_long, _), do: "timeout must be shorter than interval"

  defp message(:ntp_interval_short, _),
    do:
      "interval is shorter than 8s; NTP servers you do not run may rate-limit or drop the queries"
end
