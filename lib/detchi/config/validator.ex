defmodule Detchi.Config.Validator do
  @moduledoc """
  Turns the YAML tree into a `Detchi.Config`, checking it strictly
  (docs/basic-design.md, 7): unknown keys, duplicated keys and wrong
  types are errors, and every error in the file is reported, not only
  the first.

  Issues point at the spot by line, column and path, and never quote the
  file (see `Detchi.Config.Issue`): the file holds credentials, and a
  misplaced one can end up in a key as well as in a value.

  Each step returns `{value, issues}`, where `value` is `:invalid` when
  the step failed. Whether the whole config is valid is decided at the
  end, from whether any issue is an error.
  """

  alias Detchi.Config
  alias Detchi.Config.{Credential, Duration, Issue, Probe, Target, Yaml}

  @name_re ~r/\A[a-z0-9][a-z0-9._-]{0,62}\z/
  @oid_re ~r/\A[0-2](\.(0|[1-9][0-9]*))+\z/
  @max_oid_arc 4_294_967_295
  @hostname_label_re ~r/\A[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?\z/
  @ntp_min_interval_ms 8_000

  @top_keys ~w(data_dir retention_days compression resolve_interval defaults credentials targets)
  @defaults_keys ~w(interval timeout snmp_timeout)
  @target_keys ~w(name host family snmp probes)
  @target_snmp_keys ~w(credential port)
  @probe_keys ~w(name protocol interval timeout)

  # Keys allowed besides @probe_keys, by protocol.
  @protocol_keys %{
    "icmp" => [],
    "tcp" => ~w(port),
    "udp" => ~w(service port),
    "snmp" => ~w(oids)
  }

  # The v3 keys follow the draft in docs/basic-design.md, 7.2, so that a
  # v3 profile reports only that v3 is not supported yet.
  @credential_keys %{
    "v2c" => ~w(version community),
    "v3" => ~w(version user auth auth_pass priv priv_pass)
  }

  @any_protocol_keys @protocol_keys |> Map.values() |> Enum.concat() |> Enum.uniq()
  @any_credential_keys @credential_keys |> Map.values() |> Enum.concat() |> Enum.uniq()

  @protocols %{"icmp" => :icmp, "tcp" => :tcp, "udp" => :udp, "snmp" => :snmp}
  @services %{"dns" => :dns, "ntp" => :ntp, "quic" => :quic}
  @udp_ports %{dns: 53, ntp: 123, quic: 443}
  @families %{"auto" => :auto, "ipv4" => :ipv4, "ipv6" => :ipv6}
  @compressions %{"gzip" => :gzip, "zstd" => :zstd}

  @builtin_defaults %{interval_ms: 60_000, timeout_ms: 1_000, snmp_timeout_ms: 5_000}
  @default_data_dir "/var/lib/detchi"
  @default_retention_days 1827
  @default_resolve_interval_ms 300_000
  @default_snmp_port 161

  @spec validate(Yaml.yaml_node()) :: {:ok, Config.t(), [Issue.t()]} | {:error, [Issue.t()]}
  def validate(root) do
    {config, issues} = with_map(root, [], @top_keys, &top/3, ignore_x: true)
    {errors, warnings} = Enum.split_with(issues, &(&1.severity == :error))

    case {config, errors} do
      {%Config{}, []} -> {:ok, config, sort(warnings)}
      {_, [_ | _]} -> {:error, sort(errors)}
    end
  end

  defp sort(issues), do: Enum.sort_by(issues, &{&1.line || 0, &1.column || 0})

  ## Sections

  defp top(m, pos, path) do
    {defaults, defaults_issues} =
      optional(m, "defaults", path, @builtin_defaults, &defaults/2)

    {credentials, credential_issues} = optional(m, "credentials", path, %{}, &credentials/2)

    # A broken defaults section is reported once; the probes are then
    # checked against the built-in defaults.
    ctx = %{
      defaults: if(defaults == :invalid, do: @builtin_defaults, else: defaults),
      credentials: credentials
    }

    {fields, issues} =
      collect(
        data_dir: optional(m, "data_dir", path, @default_data_dir, &absolute_path/2),
        retention_days:
          optional(m, "retention_days", path, @default_retention_days, &positive_integer/2),
        compression: optional(m, "compression", path, :gzip, &enum(&1, &2, @compressions)),
        resolve_interval_ms:
          optional(m, "resolve_interval", path, @default_resolve_interval_ms, &duration/2),
        targets: required(m, "targets", path, pos, &targets(&1, &2, ctx))
      )

    issues = defaults_issues ++ credential_issues ++ issues
    if fields == :invalid, do: {:invalid, issues}, else: {struct!(Config, fields), issues}
  end

  defp defaults(node, path) do
    with_map(node, path, @defaults_keys, fn m, _pos, path ->
      collect(
        interval_ms: optional(m, "interval", path, @builtin_defaults.interval_ms, &duration/2),
        timeout_ms: optional(m, "timeout", path, @builtin_defaults.timeout_ms, &duration/2),
        snmp_timeout_ms:
          optional(m, "snmp_timeout", path, @builtin_defaults.snmp_timeout_ms, &duration/2)
      )
    end)
  end

  # Returns a map of profile name => %Credential{} | :invalid, so that a
  # reference to a broken profile is not reported a second time.
  defp credentials({:map, _pos, pairs}, path) do
    {profiles, issues} =
      Enum.reduce(pairs, {%{}, []}, fn {key, value}, {profiles, issues} ->
        case key do
          {:str, key_pos, name} ->
            cond do
              not Regex.match?(@name_re, name) ->
                {profiles, [issue(path, key_pos, :invalid_name) | issues]}

              Map.has_key?(profiles, name) ->
                {profiles, [issue(path ++ [name], key_pos, :duplicate_key) | issues]}

              true ->
                {credential, more} = credential(value, path ++ [name], name)
                {Map.put(profiles, name, credential), Enum.reverse(more, issues)}
            end

          other ->
            {profiles, [issue(path, node_pos(other), :invalid_name) | issues]}
        end
      end)

    {profiles, Enum.reverse(issues)}
  end

  defp credentials(node, path), do: {:invalid, [issue(path, node_pos(node), :not_a_map)]}

  defp credential(node, path, name) do
    # Without a valid version (reported), keys of any version pass.
    allowed = Map.get(@credential_keys, peek(node, "version"), @any_credential_keys)

    with_map(node, path, allowed, fn m, pos, path ->
      case required(m, "version", path, pos, &credential_version/2) do
        {:v2c, []} ->
          case required(m, "community", path, pos, &string/2) do
            {:invalid, issues} -> {:invalid, issues}
            {community, []} -> {%Credential{name: name, version: :v2c, community: community}, []}
          end

        {_, issues} ->
          {:invalid, issues}
      end
    end)
  end

  defp credential_version({:str, pos, "v3"}, path),
    do: {:invalid, [issue(path, pos, :unsupported_version)]}

  defp credential_version(node, path), do: enum(node, path, %{"v2c" => :v2c, "v3" => :v3})

  defp targets(node, path, ctx) do
    case list(node, path, &target(&1, &2, ctx)) do
      {[], issues} -> {:invalid, issues ++ [issue(path, node_pos(node), :empty_list)]}
      {targets, issues} -> {targets, issues ++ duplicate_names(node, path)}
    end
  end

  defp target(node, path, ctx) do
    with_map(node, path, @target_keys, fn m, pos, path ->
      {fields, issues} =
        collect_partial(
          name: required(m, "name", path, pos, &name/2),
          host: required(m, "host", path, pos, &host/2),
          family: optional(m, "family", path, :auto, &enum(&1, &2, @families)),
          snmp: optional(m, "snmp", path, nil, &target_snmp(&1, &2, ctx)),
          probes: required(m, "probes", path, pos, &probes(&1, &2, ctx))
        )

      # Checks that span fields run whenever the fields they read are valid.
      issues =
        issues ++
          when_valid(fields, [:host, :family], &family_issues(&1.host, &1.family, m, path)) ++
          when_valid(fields, [:probes, :snmp], &snmp_issues(&1.probes, &1.snmp, pos, path))

      if valid?(fields) do
        {host, address} = fields.host

        target = %Target{
          name: fields.name,
          host: host,
          address: address,
          family: fields.family,
          snmp: fields.snmp,
          probes: fields.probes
        }

        {target, issues}
      else
        {:invalid, issues}
      end
    end)
  end

  defp family_issues({_host, nil}, _family, _m, _path), do: []

  defp family_issues({_host, address}, family, m, path) do
    case {tuple_size(address), family} do
      {4, :ipv6} -> [issue(path ++ ["family"], value_pos(m, "family"), :family_mismatch)]
      {8, :ipv4} -> [issue(path ++ ["family"], value_pos(m, "family"), :family_mismatch)]
      _ -> []
    end
  end

  defp snmp_issues(probes, nil, pos, path) do
    if Enum.any?(probes, &(&1.protocol == :snmp)),
      do: [issue(path, pos, :snmp_missing)],
      else: []
  end

  defp snmp_issues(_probes, _snmp, _pos, _path), do: []

  defp target_snmp(node, path, ctx) do
    with_map(node, path, @target_snmp_keys, fn m, pos, path ->
      collect(
        credential: required(m, "credential", path, pos, &credential_ref(&1, &2, ctx)),
        port: optional(m, "port", path, @default_snmp_port, &port/2)
      )
    end)
  end

  defp credential_ref(node, path, ctx) do
    case string(node, path) do
      {:invalid, issues} ->
        {:invalid, issues}

      {name, []} ->
        case ctx.credentials do
          # The credentials section is broken and already reported.
          :invalid -> {:invalid, []}
          %{^name => :invalid} -> {:invalid, []}
          %{^name => credential} -> {credential, []}
          %{} -> {:invalid, [issue(path, node_pos(node), :unknown_credential)]}
        end
    end
  end

  defp probes(node, path, ctx) do
    case list(node, path, &probe(&1, &2, ctx)) do
      {[], issues} -> {:invalid, issues ++ [issue(path, node_pos(node), :empty_list)]}
      {probes, issues} -> {probes, issues ++ duplicate_names(node, path)}
    end
  end

  defp probe(node, path, ctx) do
    protocol = peek(node, "protocol")

    # Without a valid protocol (reported), keys of any protocol pass.
    allowed = @probe_keys ++ Map.get(@protocol_keys, protocol, @any_protocol_keys)

    with_map(node, path, allowed, fn m, pos, path ->
      {fields, issues} =
        collect_partial(
          [
            name: required(m, "name", path, pos, &name/2),
            protocol: required(m, "protocol", path, pos, &enum(&1, &2, @protocols)),
            interval_ms: optional(m, "interval", path, nil, &duration/2),
            timeout_ms: optional(m, "timeout", path, nil, &duration/2)
          ] ++ protocol_fields(protocol, m, pos, path)
        )

      fields = fill_probe_defaults(fields, ctx.defaults)

      issues =
        issues ++
          when_valid(fields, [:interval_ms, :timeout_ms], &timeout_issues(&1, m, pos, path)) ++
          when_valid(fields, [:interval_ms], &ntp_issues(&1, m, pos, path))

      if valid?(fields), do: {struct!(Probe, fields), issues}, else: {:invalid, issues}
    end)
  end

  defp protocol_fields("tcp", m, pos, path), do: [port: required(m, "port", path, pos, &port/2)]

  defp protocol_fields("udp", m, pos, path) do
    [
      service: required(m, "service", path, pos, &enum(&1, &2, @services)),
      port: optional(m, "port", path, nil, &port/2)
    ]
  end

  defp protocol_fields("snmp", m, pos, path), do: [oids: required(m, "oids", path, pos, &oids/2)]
  defp protocol_fields(_, _m, _pos, _path), do: []

  defp fill_probe_defaults(fields, defaults) do
    timeout =
      case fields do
        %{timeout_ms: nil, protocol: :snmp} -> defaults.snmp_timeout_ms
        # Which default applies is unknown; the protocol is reported.
        %{timeout_ms: nil, protocol: :invalid} -> :invalid
        %{timeout_ms: nil} -> defaults.timeout_ms
        %{timeout_ms: timeout} -> timeout
      end

    port =
      case fields do
        %{protocol: :udp, port: nil, service: service} when service != :invalid ->
          Map.fetch!(@udp_ports, service)

        _ ->
          Map.get(fields, :port)
      end

    fields
    |> Map.update!(:interval_ms, &(&1 || defaults.interval_ms))
    |> Map.put(:timeout_ms, timeout)
    |> Map.put(:port, port)
  end

  defp timeout_issues(%{interval_ms: interval, timeout_ms: timeout}, _m, _pos, _path)
       when timeout < interval,
       do: []

  defp timeout_issues(_fields, m, pos, path) do
    # Points at whichever of the two the probe sets, else at the probe.
    at = value_pos(m, "timeout") || value_pos(m, "interval") || pos
    [issue(path ++ ["timeout"], at, :timeout_too_long)]
  end

  defp ntp_issues(%{service: :ntp, interval_ms: interval}, m, pos, path)
       when interval < @ntp_min_interval_ms do
    at = value_pos(m, "interval") || pos
    [issue(path ++ ["interval"], at, :ntp_interval_short, severity: :warning)]
  end

  defp ntp_issues(_fields, _m, _pos, _path), do: []

  defp oids(node, path) do
    case list(node, path, &oid/2) do
      {[], issues} -> {:invalid, issues ++ [issue(path, node_pos(node), :empty_list)]}
      result -> result
    end
  end

  defp oid({:str, pos, text}, path) do
    with true <- Regex.match?(@oid_re, text),
         arcs = text |> String.split(".") |> Enum.map(&String.to_integer/1),
         true <- Enum.all?(arcs, &(&1 <= @max_oid_arc)) do
      {arcs, []}
    else
      false -> {:invalid, [issue(path, pos, :invalid_oid)]}
    end
  end

  defp oid(node, path), do: {:invalid, [issue(path, node_pos(node), :invalid_oid)]}

  ## Scalars

  defp string({:str, _pos, text}, _path) when text != "", do: {text, []}
  defp string(node, path), do: {:invalid, [issue(path, node_pos(node), :not_a_string)]}

  defp name(node, path) do
    case string(node, path) do
      {:invalid, issues} ->
        {:invalid, issues}

      {text, []} ->
        if Regex.match?(@name_re, text),
          do: {text, []},
          else: {:invalid, [issue(path, node_pos(node), :invalid_name)]}
    end
  end

  defp absolute_path({:str, _pos, "/" <> _ = text}, _path), do: {text, []}
  defp absolute_path(node, path), do: {:invalid, [issue(path, node_pos(node), :invalid_path)]}

  defp duration({:str, _pos, text} = node, path) do
    case Duration.parse(text) do
      {:ok, ms} -> {ms, []}
      :error -> {:invalid, [issue(path, node_pos(node), :invalid_duration)]}
    end
  end

  defp duration(node, path), do: {:invalid, [issue(path, node_pos(node), :invalid_duration)]}

  defp positive_integer({:int, _pos, value}, _path) when value > 0, do: {value, []}

  defp positive_integer(node, path),
    do: {:invalid, [issue(path, node_pos(node), :invalid_integer)]}

  defp port({:int, _pos, value}, _path) when value in 1..65_535, do: {value, []}
  defp port(node, path), do: {:invalid, [issue(path, node_pos(node), :invalid_port)]}

  defp enum({:str, _pos, text} = node, path, values) do
    case Map.fetch(values, text) do
      {:ok, value} -> {value, []}
      :error -> enum_issue(node, path, values)
    end
  end

  defp enum(node, path, values), do: enum_issue(node, path, values)

  defp enum_issue(node, path, values) do
    allowed = values |> Map.keys() |> Enum.sort()
    {:invalid, [issue(path, node_pos(node), :invalid_value, detail: [allowed: allowed])]}
  end

  # Returns {host, address}, where address is nil for a host name.
  defp host(node, path) do
    case string(node, path) do
      {:invalid, issues} ->
        {:invalid, issues}

      {text, []} ->
        case :inet.parse_strict_address(String.to_charlist(text)) do
          # The parser drops a zone ("fe80::1%eth0"), so refuse it.
          {:ok, address} ->
            if String.contains?(text, "%"),
              do: {:invalid, [issue(path, node_pos(node), :invalid_host)]},
              else: {{text, address}, []}

          {:error, _} ->
            if hostname?(text),
              do: {{text, nil}, []},
              else: {:invalid, [issue(path, node_pos(node), :invalid_host)]}
        end
    end
  end

  # A name made of DNS labels whose last label is not all digits, so that
  # a mistyped IPv4 address such as 192.0.2.300 is not taken for a name.
  defp hostname?(text) do
    labels = text |> String.trim_trailing(".") |> String.split(".")

    byte_size(text) <= 253 and
      Enum.all?(labels, &Regex.match?(@hostname_label_re, &1)) and
      not String.match?(List.last(labels), ~r/\A[0-9]+\z/)
  end

  ## Helpers

  # Runs fun.(entries, pos, path) on a mapping whose keys are checked
  # against `allowed`. Entries are keyed by key text and hold
  # {key_pos, value_node}.
  defp with_map(node, path, allowed, fun, opts \\ [])

  defp with_map({:map, pos, pairs}, path, allowed, fun, opts) do
    ignore_x = Keyword.get(opts, :ignore_x, false)

    {m, issues} =
      Enum.reduce(pairs, {%{}, []}, fn {key, value}, {m, issues} ->
        case key do
          # Extension fields hold YAML anchors (docs/basic-design.md, 7.7).
          {:str, _key_pos, "x-" <> _} when ignore_x ->
            {m, issues}

          {:str, key_pos, text} ->
            cond do
              text not in allowed ->
                {m, [issue(path, key_pos, :unknown_key) | issues]}

              Map.has_key?(m, text) ->
                {m, [issue(path ++ [text], key_pos, :duplicate_key) | issues]}

              true ->
                {Map.put(m, text, {key_pos, value}), issues}
            end

          other ->
            {m, [issue(path, node_pos(other), :unknown_key) | issues]}
        end
      end)

    {value, more} = fun.(m, pos, path)
    {value, Enum.reverse(issues, more)}
  end

  defp with_map(node, path, _allowed, _fun, _opts),
    do: {:invalid, [issue(path, node_pos(node), :not_a_map)]}

  defp required(m, key, path, parent_pos, fun) do
    case m do
      %{^key => {_key_pos, node}} -> fun.(node, path ++ [key])
      %{} -> {:invalid, [issue(path, parent_pos, :missing_key, detail: [key: key])]}
    end
  end

  defp optional(m, key, path, default, fun) do
    case m do
      %{^key => {_key_pos, node}} -> fun.(node, path ++ [key])
      %{} -> {default, []}
    end
  end

  defp list({:seq, _pos, items}, path, fun) do
    {values, issues} =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, index} -> fun.(item, path ++ [index]) end)
      |> Enum.unzip()

    issues = List.flatten(issues)
    if :invalid in values, do: {:invalid, issues}, else: {values, issues}
  end

  defp list(node, path, _fun), do: {:invalid, [issue(path, node_pos(node), :not_a_list)]}

  # Collects {field, {value, issues}} into a map of the fields, or
  # :invalid if any field is.
  defp collect(results) do
    {values, issues} = collect_partial(results)
    if valid?(values), do: {values, issues}, else: {:invalid, issues}
  end

  # Like collect/1, but keeps the map with :invalid in the failed fields,
  # for checks that read only some of them.
  defp collect_partial(results) do
    values = Map.new(results, fn {field, {value, _}} -> {field, value} end)
    issues = Enum.flat_map(results, fn {_, {_, issues}} -> issues end)
    {values, issues}
  end

  defp valid?(values), do: not Enum.any?(values, fn {_, value} -> value == :invalid end)

  defp when_valid(values, keys, fun) do
    if valid?(Map.take(values, keys)), do: fun.(values), else: []
  end

  # Reports later uses of a name already used in the same list. Names
  # that break the name rule are reported elsewhere and skipped here.
  defp duplicate_names({:seq, _pos, items}, path) do
    items
    |> Enum.with_index()
    |> Enum.reduce({%{}, []}, fn {item, index}, {seen, issues} ->
      case peek_node(item, "name") do
        {:str, {line, _} = pos, name} ->
          cond do
            not Regex.match?(@name_re, name) ->
              {seen, issues}

            Map.has_key?(seen, name) ->
              detail = [line: Map.fetch!(seen, name)]

              {seen,
               [issue(path ++ [index, "name"], pos, :duplicate_name, detail: detail) | issues]}

            true ->
              {Map.put(seen, name, line), issues}
          end

        _ ->
          {seen, issues}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp duplicate_names(_node, _path), do: []

  # The text of a string value in a mapping, without checking anything.
  defp peek(node, key) do
    case peek_node(node, key) do
      {:str, _pos, text} -> text
      _ -> nil
    end
  end

  defp peek_node({:map, _pos, pairs}, key) do
    Enum.find_value(pairs, fn
      {{:str, _, ^key}, value} -> value
      _ -> nil
    end)
  end

  defp peek_node(_node, _key), do: nil

  defp value_pos(m, key) do
    case m do
      %{^key => {_key_pos, node}} -> node_pos(node)
      %{} -> nil
    end
  end

  defp node_pos(node), do: elem(node, 1)

  defp issue(path, {line, column}, reason, opts \\ []) do
    %Issue{
      severity: Keyword.get(opts, :severity, :error),
      path: path,
      line: line,
      column: column,
      reason: reason,
      detail: Keyword.get(opts, :detail, [])
    }
  end
end
