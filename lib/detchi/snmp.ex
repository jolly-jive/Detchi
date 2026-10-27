defmodule Detchi.Snmp do
  @moduledoc """
  SNMP through the manager of OTP, `snmpm` (docs/basic-design.md, 5).

  `detchi run` writes the config files of the manager to a directory of
  its own under the temporary directory, and starts `snmp` with the
  manager's `restart_type` `permanent`: if the manager fails, its
  registrations are gone with it, so the VM is stopped instead and left
  to be restarted from outside (docs/basic-design.md, 3.1).

  Each target with SNMP is registered as an agent named after the
  target, by its Resolver. A registration always removes the previous
  one first, so that a restarted Resolver and a changed address are
  handled the same way.

  Nothing here may put a credential in an error, an exception or a log
  line (docs/basic-design.md, 7.8): errors of `snmpm` are described by
  the names of their kinds only.
  """

  alias Detchi.Config.Probe

  @user :detchi
  @engine_id ~c"detchi"
  @max_message_size 65_535

  @type result :: %{
          required(:ts) => integer(),
          required(:addr) => :inet.ip_address(),
          required(:port) => :inet.port_number(),
          required(:status) => :ok | :timeout | :error,
          optional(:rtt_us) => non_neg_integer(),
          optional(:timeout_ms) => pos_integer(),
          optional(:error) => Detchi.Record.error(),
          optional(:snmp) => map()
        }

  @doc """
  Writes the config files of the manager to `<tmp_dir>/detchi-<OS pid>`
  and puts the config of the manager in the environment of `snmp`, to be
  started next. Returns the directory, to be removed on stop.

  The manager listens on a port the OS chooses, and accepts messages up
  to 65535 bytes; agents answer `tooBig` to requests whose replies are
  larger than they take. It listens on IPv4, and on IPv6 if a UDP socket
  can be bound to it, so that `snmp` still starts on a host without
  IPv6. Targets of a family the manager does not listen on are written
  as `internal`.
  """
  @spec configure(Path.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def configure(tmp_dir) do
    dir = Path.join(tmp_dir, "detchi-#{System.pid()}")
    db_dir = Path.join(dir, "db")
    conf = String.to_charlist(dir)

    families = Enum.filter([:inet, :inet6], &bindable?/1)
    :persistent_term.put({__MODULE__, :families}, families)

    entries = [
      :snmpm_conf.manager_entry(:port, 0),
      :snmpm_conf.manager_entry(:transports, Enum.map(families, &{domain(&1), {any(&1), 0}})),
      :snmpm_conf.manager_entry(:engine_id, @engine_id),
      :snmpm_conf.manager_entry(:max_message_size, @max_message_size)
    ]

    with _ <- File.rm_rf(dir),
         :ok <- mkdir(db_dir),
         :ok <- write(:manager, fn -> :snmpm_conf.write_manager_config(conf, entries) end),
         :ok <- write(:users, fn -> :snmpm_conf.write_users_config(conf, []) end),
         :ok <- write(:agents, fn -> :snmpm_conf.write_agents_config(conf, []) end),
         :ok <- write(:usm, fn -> :snmpm_conf.write_usm_config(conf, []) end) do
      Application.put_env(:snmp, :manager,
        config: [dir: conf, db_dir: String.to_charlist(db_dir)],
        restart_type: :permanent
      )

      {:ok, dir}
    end
  end

  defp bindable?(family) do
    with {:ok, socket} <- :socket.open(family, :dgram, :udp) do
      try do
        :socket.bind(socket, %{family: family, addr: :any, port: 0}) == :ok
      after
        :socket.close(socket)
      end
    else
      _ -> false
    end
  end

  defp domain(:inet), do: :transportDomainUdpIpv4
  defp domain(:inet6), do: :transportDomainUdpIpv6

  defp any(:inet), do: {0, 0, 0, 0}
  defp any(:inet6), do: {0, 0, 0, 0, 0, 0, 0, 0}

  defp family({_, _, _, _}), do: :inet
  defp family({_, _, _, _, _, _, _, _}), do: :inet6

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, errno} -> {:error, "cannot create #{dir} (#{errno})"}
    end
  end

  defp write(file, fun) do
    case fun.() do
      :ok -> :ok
      _ -> {:error, "cannot write the #{file} config of the SNMP manager"}
    end
  end

  @doc "Registers the user of Detchi in `snmpm`, which drops all it is told."
  @spec register_user() :: :ok
  def register_user do
    case :snmpm.register_user(@user, Detchi.Snmp.User, nil) do
      :ok -> :ok
      {:error, reason} -> raise "cannot register the SNMP user (#{describe(reason)})"
    end
  end

  @doc """
  Registers a target in `snmpm` at `addr`, with the port and the
  credential of its `snmp`, removing the previous registration first.
  """
  @spec register(String.t(), :inet.ip_address(), Detchi.Config.Target.snmp()) :: :ok
  def register(target, addr, %{credential: credential, port: port}) do
    agent = String.to_charlist(target)

    # {:error, :not_found} when there was none.
    _ = :snmpm.unregister_agent(@user, agent)

    config =
      [tdomain: domain(family(addr)), address: addr, port: port, engine_id: @engine_id] ++
        security(credential) ++ [max_message_size: @max_message_size]

    case :snmpm.register_agent(@user, agent, config) do
      :ok -> :ok
      {:error, reason} -> raise "cannot register #{target} in snmpm (#{describe(reason)})"
    end
  end

  defp security(%{version: :v2c, community: community}),
    do: [version: :v2, sec_model: :v2c, community: String.to_charlist(community)]

  @doc """
  Gets the OIDs of the probe from a target, as a probe's attempt.

  Returns the fields of the measurement line that depend on the result.
  `addr` and `port` are those `snmpm` sends to, read just before the
  request, so that the line does not miss a change of the address. `ts`
  and the RTT start just before `snmpm:sync_get2/4` is called; `snmpm`
  builds and sends the request in its own processes
  (docs/basic-design.md, 5).

  Raises on the errors of `snmpm` that are not about the target (the
  target is not registered, the request is too large to send), which
  the probe writes as `internal`.
  """
  @spec measure(String.t(), :v2c, Probe.t()) :: result()
  def measure(target, version, %Probe{oids: oids, timeout_ms: timeout_ms}) do
    agent = String.to_charlist(target)

    {addr, port} =
      case :snmpm.agent_info(agent, :taddress) do
        {:ok, {addr, port}} -> {addr, port}
        {:error, reason} -> raise "cannot get the address of #{target} (#{describe(reason)})"
      end

    # snmpm would log that it has no transport, and let the request time out.
    unless family(addr) in :persistent_term.get({__MODULE__, :families}, []),
      do: raise("the SNMP manager does not listen on #{family(addr)}")

    ts = System.os_time(:microsecond)
    started = System.monotonic_time(:microsecond)
    outcome = :snmpm.sync_get2(@user, agent, oids, timeout: timeout_ms)
    rtt_us = System.monotonic_time(:microsecond) - started
    line = %{ts: ts, addr: addr, port: port}
    snmp = %{version: version, op: :get}

    case outcome do
      {:ok, {:noError, 0, varbinds}, _} ->
        varbinds =
          Enum.map(varbinds, fn {:varbind, oid, type, value, _} -> {oid, type, value} end)

        Map.merge(line, %{status: :ok, rtt_us: rtt_us, snmp: Map.put(snmp, :varbinds, varbinds)})

      {:ok, {status, index, _}, _} ->
        Map.merge(line, %{
          status: :error,
          rtt_us: rtt_us,
          error: {:snmp, status, index},
          snmp: snmp
        })

      {:error, {:timeout, _}} ->
        Map.merge(line, %{status: :timeout, timeout_ms: timeout_ms, snmp: snmp})

      {:error, reason} ->
        raise "sync_get2 failed (#{describe(reason)})"
    end
  end

  # Only the names of the kinds: the terms of snmpm may hold the config
  # of an agent, with its community.
  defp describe({:send_failed, _req_id, reason}) when is_atom(reason),
    do: "send_failed, #{reason}"

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp describe(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  defp describe(_reason), do: "unexpected"
end
