defmodule Detchi.Config.DurationTest do
  use ExUnit.Case, async: true

  alias Detchi.Config.Duration

  test "parses each unit into milliseconds" do
    assert Duration.parse("500ms") == {:ok, 500}
    assert Duration.parse("60s") == {:ok, 60_000}
    assert Duration.parse("5m") == {:ok, 300_000}
    assert Duration.parse("1h") == {:ok, 3_600_000}
  end

  test "rejects durations without a unit, zero, fractions and padding" do
    for text <- ["60", "0s", "05s", "1.5s", "-1s", " 1s", "1s ", "1 s", "1d", "1S", ""] do
      assert Duration.parse(text) == :error, text
    end
  end
end
