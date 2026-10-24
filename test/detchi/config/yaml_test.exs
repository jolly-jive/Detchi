defmodule Detchi.Config.YamlTest do
  use ExUnit.Case, async: true

  alias Detchi.Config.Yaml

  test "keeps positions and scalar types" do
    assert {:ok, {:map, {1, 1}, pairs}} = Yaml.parse("a: 1\nb: x\nc: 1.3\nd: ~\ne: true\n")

    assert pairs == [
             {{:str, {1, 1}, "a"}, {:int, {1, 4}, 1}},
             {{:str, {2, 1}, "b"}, {:str, {2, 4}, "x"}},
             {{:str, {3, 1}, "c"}, {:float, {3, 4}, 1.3}},
             {{:str, {4, 1}, "d"}, {:null, {4, 4}}},
             {{:str, {5, 1}, "e"}, {:bool, {5, 4}, true}}
           ]
  end

  test "keeps both copies of a duplicated key" do
    assert {:ok, {:map, _, [{{:str, _, "a"}, _}, {{:str, _, "a"}, _}]}} =
             Yaml.parse("a: 1\na: 2\n")
  end

  test "expands anchors on block collections and scalars" do
    assert {:ok, {:map, _, [_, {_, {:seq, _, [{:int, _, 1}, {:int, _, 2}]}}]}} =
             Yaml.parse("x:\n  &s\n  - 1\n  - 2\ny: *s\n")

    assert {:ok, {:map, _, [_, {_, {:map, _, [_]}}]}} = Yaml.parse("x: &s\n  a: 1\ny: *s\n")
    assert {:ok, {:map, _, [_, {_, {:str, _, "a"}}]}} = Yaml.parse("x: &s a\ny: *s\n")

    # An anchor inside a flow collection is fine.
    assert {:ok, {:map, _, [{_, {:seq, _, [{:int, _, 1}]}}, {_, {:int, _, 1}}]}} =
             Yaml.parse("x: [&s 1]\ny: *s\n")
  end

  test "rejects anchors on flow collections, which yamerl gets wrong" do
    # yamerl 0.10 would make *s stand for the first scalar inside.
    assert Yaml.parse("x: &s [1, 2]\ny: *s\n") == {:error, {:flow_anchor, 1, 4}}
    assert Yaml.parse("a: 1\nx: &s {k: v}\ny: *s\n") == {:error, {:flow_anchor, 2, 4}}
    assert Yaml.parse("x: !!seq &s [1]\n") == {:error, {:flow_anchor, 1, 10}}
    assert Yaml.parse("x: [1, &s [2]]\n") == {:error, {:flow_anchor, 1, 8}}

    # The example of docs/basic-design.md, 7.7: a block list of flow maps.
    assert {:ok, _} = Yaml.parse("x: &s\n  - { name: ping }\n  - { name: ssh }\ny: *s\n")
  end

  test "leaves merge keys as plain keys" do
    assert {:ok, {:map, _, [_, {_, {:map, _, [{{:str, _, "<<"}, _}]}}]}} =
             Yaml.parse("x: &s\n  a: 1\ny: {<<: *s}\n")
  end

  test "rejects an empty file and several documents" do
    assert Yaml.parse("") == {:error, :empty_document}
    assert Yaml.parse("# only a comment\n") == {:error, :empty_document}
    assert Yaml.parse("a: 1\n---\nb: 2\n") == {:error, :multiple_documents}
  end

  test "reports a syntax error by position and type only" do
    # yamerl's own error holds the text "s3cr3t-community b: [".
    assert Yaml.parse("a: \"s3cr3t-community\nb: [\n") ==
             {:error, {:yaml_syntax, 3, 1, :unexpected_eos}}
  end
end
