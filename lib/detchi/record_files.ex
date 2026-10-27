defmodule Detchi.RecordFiles do
  @moduledoc """
  The naming rule of the record files (docs/basic-design.md, 6.2):
  `<data_dir>/<target>/<target>-YYYY-MM-DD.jsonl`, `.jsonl.gz` or
  `.jsonl.zst`, and `.part` for a compressed file being made.

  Only names that match the rule exactly are taken, so that files put
  there by people are left alone.
  """

  @name_re ~r/\A[a-z0-9][a-z0-9._-]{0,62}\z/
  # After `<target>-`. Only compressed files have `.part` ones.
  @file_re ~r/\A(?<date>\d{4}-\d{2}-\d{2})\.jsonl(?:\.(?<ext>gz|zst)(?<part>\.part)?)?\z/

  @doc "Whether `name` has the form of a target name, and so of its directory."
  @spec target_name?(String.t()) :: boolean()
  def target_name?(name), do: name =~ @name_re

  @doc """
  Parses the name of a file in the directory of `target` into
  `{date, nil | "gz" | "zst", part?}`, or `nil` if it does not match the
  rule. The date is the `YYYY-MM-DD` of the name, and is a real date.
  """
  @spec parse(String.t(), String.t()) :: {String.t(), nil | String.t(), boolean()} | nil
  def parse(target, name) do
    prefix = target <> "-"

    with true <- String.starts_with?(name, prefix),
         rest = binary_part(name, byte_size(prefix), byte_size(name) - byte_size(prefix)),
         %{"date" => date, "ext" => ext, "part" => part} <- Regex.named_captures(@file_re, rest),
         {:ok, _} <- Date.from_iso8601(date) do
      {date, if(ext == "", do: nil, else: ext), part != ""}
    else
      _ -> nil
    end
  end
end
