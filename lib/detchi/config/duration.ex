defmodule Detchi.Config.Duration do
  @moduledoc """
  Durations in the config file: a positive integer with a unit, such as
  `500ms`, `60s`, `5m` or `1h` (docs/basic-design.md, 7.3).
  """

  @units %{"ms" => 1, "s" => 1_000, "m" => 60_000, "h" => 3_600_000}

  @doc "Parses a duration into milliseconds."
  @spec parse(String.t()) :: {:ok, pos_integer()} | :error
  def parse(text) when is_binary(text) do
    case Regex.run(~r/\A([1-9][0-9]*)(ms|s|m|h)\z/, text) do
      [_, number, unit] -> {:ok, String.to_integer(number) * Map.fetch!(@units, unit)}
      nil -> :error
    end
  end
end
