defmodule Detchi.Config do
  @moduledoc """
  The validated config (docs/basic-design.md, 7).

  `load/1` is shared by `detchi run`, `detchi check-config` and, later,
  `detchi status`.
  """

  alias Detchi.Config.{Issue, Target, Validator, Yaml}

  @default_path "/etc/detchi/detchi.yml"

  @enforce_keys [:data_dir, :retention_days, :compression, :resolve_interval_ms, :targets]
  defstruct [:data_dir, :retention_days, :compression, :resolve_interval_ms, :targets]

  @type t :: %__MODULE__{
          data_dir: String.t(),
          retention_days: pos_integer(),
          compression: :gzip | :zstd,
          resolve_interval_ms: pos_integer(),
          targets: [Target.t()]
        }

  @doc "The config file path: `DETCHI_CONFIG`, or #{@default_path}."
  @spec path() :: Path.t()
  def path do
    case System.get_env("DETCHI_CONFIG") do
      nil -> @default_path
      "" -> @default_path
      path -> path
    end
  end

  @doc """
  Reads and validates a config file. Warnings come with a valid config;
  on errors, only the errors are returned.
  """
  @spec load(Path.t()) :: {:ok, t(), [Issue.t()]} | {:error, [Issue.t()]}
  def load(path) do
    with {:ok, text} <- read(path),
         {:ok, root} <- parse(text) do
      Validator.validate(root)
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, errno} -> {:error, [%Issue{reason: :file_error, detail: [errno: errno]}]}
    end
  end

  defp parse(text) do
    case Yaml.parse(text) do
      {:ok, root} ->
        {:ok, root}

      {:error, {:yaml_syntax, line, column, type}} ->
        {:error, [%Issue{reason: :yaml_syntax, line: line, column: column, detail: [type: type]}]}

      {:error, {:flow_anchor, line, column}} ->
        {:error, [%Issue{reason: :flow_anchor, line: line, column: column}]}

      {:error, reason} ->
        {:error, [%Issue{reason: reason}]}
    end
  end
end
