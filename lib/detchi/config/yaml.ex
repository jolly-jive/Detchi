defmodule Detchi.Config.Yaml do
  @moduledoc """
  Reads YAML into a small tree of tagged tuples that keep the line and
  column of every node.

  yamerl is called directly rather than through yaml_elixir, which keeps
  only the last of duplicated keys and the last of several documents;
  both must be errors here (docs/basic-design.md, 7.1).

  yamerl's errors carry the text around the broken spot, which may hold
  a credential, so only the line, the column and the error type are kept.

  yamerl 0.10 puts an anchor on a flow collection (`&a [1, 2]`,
  `&a {k: v}`) on the first scalar inside it instead, so `*a` would
  stand for `1` or `k`. Such anchors are rejected; anchors on block
  collections and on scalars work.
  """

  @type pos :: {pos_integer(), pos_integer()}
  @type yaml_node ::
          {:map, pos, [{yaml_node, yaml_node}]}
          | {:seq, pos, [yaml_node]}
          | {:str, pos, String.t()}
          | {:int, pos, integer()}
          | {:float, pos, float() | atom()}
          | {:bool, pos, boolean()}
          | {:null, pos}
          | {:other, pos}

  @type error ::
          :empty_document
          | :multiple_documents
          | {:yaml_syntax, pos_integer() | nil, pos_integer() | nil, atom()}
          | {:flow_anchor, pos_integer(), pos_integer()}

  @options [detailed_constr: true, str_node_as_binary: true, keep_duplicate_keys: true]

  @spec parse(binary()) :: {:ok, yaml_node} | {:error, error}
  def parse(text) when is_binary(text) do
    {:ok, _} = Application.ensure_all_started(:yamerl)

    :yamerl_parser.string(text, token_fun: check_anchors(nil))

    case :yamerl_constr.string(text, @options) do
      [] -> {:error, :empty_document}
      [{:yamerl_doc, root}] -> {:ok, convert(root)}
      [_, _ | _] -> {:error, :multiple_documents}
    end
  catch
    :throw, {:yamerl_exception, [{:yamerl_parsing_error, _, _, line, column, type, _, _} | _]} ->
      {:error, {:yaml_syntax, line, column, type}}

    :throw, {:flow_anchor, line, column} ->
      {:error, {:flow_anchor, line, column}}

    # Anything else from yamerl is reported without its contents too.
    _kind, _reason ->
      {:error, {:yaml_syntax, nil, nil, :malformed}}
  end

  # A token fun that remembers the last flow collection start. yamerl
  # emits an anchor in order, except one on a flow collection, which comes
  # after the collection start although it stands before it in the text.
  defp check_anchors(last_flow_start) do
    fn
      {:yamerl_collection_start, line, column, _tag, :flow, _kind} ->
        {:ok, check_anchors({line, column})}

      {:yamerl_anchor, line, column, _name} when {line, column} < last_flow_start ->
        throw({:flow_anchor, line, column})

      _token ->
        :ok
    end
  end

  defp convert({:yamerl_map, _, _, pres, pairs}),
    do: {:map, pos(pres), Enum.map(pairs, fn {k, v} -> {convert(k), convert(v)} end)}

  defp convert({:yamerl_seq, _, _, pres, entries, _count}),
    do: {:seq, pos(pres), Enum.map(entries, &convert/1)}

  defp convert({:yamerl_str, _, _, pres, text}), do: {:str, pos(pres), text}
  defp convert({:yamerl_int, _, _, pres, value}), do: {:int, pos(pres), value}
  defp convert({:yamerl_float, _, _, pres, value}), do: {:float, pos(pres), value}
  defp convert({:yamerl_bool, _, _, pres, value}), do: {:bool, pos(pres), value}
  defp convert({:yamerl_null, _, _, pres}), do: {:null, pos(pres)}

  defp convert(node) when is_tuple(node) and tuple_size(node) >= 4,
    do: {:other, pos(elem(node, 3))}

  defp pos(pres) when is_list(pres),
    do: {Keyword.get(pres, :line, 1), Keyword.get(pres, :column, 1)}

  defp pos(_), do: {1, 1}
end
