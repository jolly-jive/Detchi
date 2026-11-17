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

  A v3 target is registered without its engine ID, which the first
  attempt discovers (`Detchi.Snmp.Discovery`); the USM user of the
  target is then registered with keys localized to it. A registration
  again, as for a new address, forgets the engine ID, and so does a
  report of `usmStatsUnknownEngineIDs`.

  `snmpm` hands the reports that pass authentication to
  `Detchi.Snmp.User`, not to the request waiting for them; the user
  passes them on to the attempts waiting on the target. A report of
  `usmStatsNotInTimeWindows` means `snmpm` has just learned the time of
  the agent, and the attempt sends its request once more: this is the
  time synchronization of RFC 3414, 2.3, needed after Detchi starts and
  after the agent restarts, and not a retry of a lost request.

  Nothing here may put a credential in an error, an exception or a log
  line (docs/basic-design.md, 7.8): errors of `snmpm` are described by
  the names of their kinds only. The v3 user name counts as one.
  """

  alias Detchi.Config.{Credential, Probe}
  alias Detchi.Snmp.Discovery

  @user :detchi
  @engine_id ~c"detchi"
  # The engine ID of a v3 target that has not been discovered yet.
  @unknown_engine_id ~c""
  @max_message_size 65_535
  @waiters Detchi.Snmp.Waiters

  @usm_stats_not_in_time_windows [1, 3, 6, 1, 6, 3, 15, 1, 1, 2, 0]
  @usm_stats_unknown_engine_ids [1, 3, 6, 1, 6, 3, 15, 1, 1, 4, 0]

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

  @doc """
  Registers the user of Detchi in `snmpm`, and creates the table of the
  attempts waiting for reports, owned by the caller.
  """
  @spec register_user() :: :ok
  def register_user do
    :ets.new(@waiters, [:bag, :public, :named_table])

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
      [tdomain: domain(family(addr)), address: addr, port: port] ++
        security(credential) ++ [max_message_size: @max_message_size]

    case :snmpm.register_agent(@user, agent, config) do
      :ok -> :ok
      {:error, reason} -> raise "cannot register #{target} in snmpm (#{describe(reason)})"
    end
  end

  defp security(%Credential{version: :v2c, community: community}) do
    [
      engine_id: @engine_id,
      version: :v2,
      sec_model: :v2c,
      community: String.to_charlist(community)
    ]
  end

  defp security(%Credential{version: :v3, user: user} = credential) do
    [
      engine_id: @unknown_engine_id,
      version: :v3,
      sec_model: :usm,
      sec_name: :binary.bin_to_list(user),
      sec_level: Credential.sec_level(credential)
    ]
  end

  @doc false
  # The attempts waiting for reports from a target, for Detchi.Snmp.User.
  @spec waiters(charlist()) :: [pid()]
  def waiters(agent) do
    for {_, pid} <- :ets.lookup(@waiters, agent), do: pid
  rescue
    # No table: Detchi is stopping, or not running.
    ArgumentError -> []
  end

  @doc """
  Gets the OIDs of the probe from a target, as a probe's attempt.

  Returns the fields of the measurement line that depend on the result.
  `addr` and `port` are those `snmpm` sends to, read just before the
  request, so that the line does not miss a change of the address. `ts`
  and the RTT start just before `snmpm:sync_get2/4` is called; `snmpm`
  builds and sends the request in its own processes
  (docs/basic-design.md, 5).

  For v3, the engine ID is discovered first if it is not known, and the
  request is sent once more after a report of `usmStatsNotInTimeWindows`
  (see the moduledoc). All of it shares the timeout of the probe; a
  discovery without an answer is a `timeout`, with the `ts` of its start.

  Raises on the errors of `snmpm` that are not about the target (the
  target is not registered, the request is too large to send), which
  the probe writes as `internal`.
  """
  @spec measure(String.t(), Credential.t(), Probe.t()) :: result()
  def measure(target, %Credential{} = credential, %Probe{oids: oids, timeout_ms: timeout_ms}) do
    agent = String.to_charlist(target)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    {addr, port} =
      case :snmpm.agent_info(agent, :taddress) do
        {:ok, {addr, port}} -> {addr, port}
        {:error, reason} -> raise "cannot get the address of #{target} (#{describe(reason)})"
      end

    # snmpm would log that it has no transport, and let the request time out.
    unless family(addr) in :persistent_term.get({__MODULE__, :families}, []),
      do: raise("the SNMP manager does not listen on #{family(addr)}")

    line = %{addr: addr, port: port}
    snmp = %{version: credential.version, op: :get}
    ts = System.os_time(:microsecond)

    case engine(agent, credential, addr, port, deadline) do
      :ok ->
        :ets.insert(@waiters, {agent, self()})

        try do
          request(agent, oids, deadline, credential.version == :v3)
        after
          :ets.delete_object(@waiters, {agent, self()})
        end
        |> result(agent, line, snmp, timeout_ms)

      :timeout ->
        Map.merge(line, %{ts: ts, status: :timeout, timeout_ms: timeout_ms, snmp: snmp})
    end
  end

  # Makes sure snmpm knows the engine ID of a v3 target and its USM user.
  defp engine(_agent, %Credential{version: :v2c}, _addr, _port, _deadline), do: :ok

  defp engine(agent, credential, addr, port, deadline) do
    if engine_id(agent) == @unknown_engine_id do
      # One discovery per target at a time; the others wait for it.
      locked(agent, deadline, fn ->
        if engine_id(agent) == @unknown_engine_id,
          do: discover(agent, credential, addr, port, deadline),
          else: :ok
      end)
    else
      :ok
    end
  end

  defp engine_id(agent) do
    case :snmpm.agent_info(agent, :engine_id) do
      {:ok, engine_id} -> engine_id
      {:error, reason} -> raise "cannot get the engine ID of an agent (#{describe(reason)})"
    end
  end

  defp locked(agent, deadline, fun) do
    # global releases the lock if the holder dies.
    id = {{__MODULE__, agent}, self()}

    cond do
      :global.set_lock(id, [node()], 0) ->
        try do
          fun.()
        after
          :global.del_lock(id, [node()])
        end

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(10)
        locked(agent, deadline, fun)
    end
  end

  defp discover(agent, credential, addr, port, deadline) do
    with {:ok, engine_id} <- Discovery.discover(addr, port, deadline) do
      usm_user(agent, engine_id, credential)

      case :snmpm.update_agent_info(@user, agent, :engine_id, engine_id) do
        :ok -> :ok
        {:error, reason} -> raise "cannot set the engine ID of an agent (#{describe(reason)})"
      end
    end
  end

  # snmpm holds one USM user per engine ID and user name, so targets that
  # reach the same agent with the same user share it. A target whose keys
  # differ from those registered does not replace them: the target that
  # registered them would fail from then on, with nothing to tell why
  # (docs/basic-design.md, 5). The table of the waiters keeps who did.
  defp usm_user(agent, engine_id, credential) do
    user = :binary.bin_to_list(credential.user)
    config = usm(credential, engine_id)
    owner = {:usm, engine_id, user}

    cond do
      :snmpm.usm_user_info(engine_id, user, :auth) == {:error, :not_found} ->
        case :snmpm.register_usm_user(engine_id, user, config) do
          :ok -> :ets.insert(@waiters, {owner, agent})
          {:error, reason} -> raise "cannot register the USM user (#{describe(reason)})"
        end

      Enum.all?(config, fn {item, value} ->
        :snmpm.usm_user_info(engine_id, user, item) == {:ok, value}
      end) ->
        :ok

      true ->
        others = Enum.map_join(:ets.lookup(@waiters, owner), ", ", fn {_, other} -> other end)

        raise "#{agent} reaches the same SNMP engine with the same v3 user as #{others}, " <>
                "but with another credential; check the credentials of both"
    end
  end

  defp forget_engine(agent),
    do: :snmpm.update_agent_info(@user, agent, :engine_id, @unknown_engine_id)

  # Keys localized to the engine ID (RFC 3414, A.2). The privacy key is
  # the first 16 bytes of one made with the hash of auth: for DES, the
  # key and the pre-IV (RFC 3414, 8.1.1.1); for AES-128, the key (RFC
  # 3826, 1.2).
  defp usm(%Credential{auth: nil}, _engine_id),
    do: [auth: :usmNoAuthProtocol, priv: :usmNoPrivProtocol]

  defp usm(%Credential{auth: auth} = credential, engine_id) do
    priv =
      case credential.priv do
        nil ->
          [priv: :usmNoPrivProtocol]

        priv ->
          key = key(auth, credential.priv_pass, engine_id)
          [priv: priv_protocol(priv), priv_key: Enum.take(key, 16)]
      end

    [auth: auth_protocol(auth), auth_key: key(auth, credential.auth_pass, engine_id)] ++ priv
  end

  defp key(auth, passphrase, engine_id),
    do: :snmp.passwd2localized_key(auth, :binary.bin_to_list(passphrase), engine_id)

  defp auth_protocol(:md5), do: :usmHMACMD5AuthProtocol
  defp auth_protocol(:sha), do: :usmHMACSHAAuthProtocol
  defp auth_protocol(:sha224), do: :usmHMAC128SHA224AuthProtocol
  defp auth_protocol(:sha256), do: :usmHMAC192SHA256AuthProtocol
  defp auth_protocol(:sha384), do: :usmHMAC256SHA384AuthProtocol
  defp auth_protocol(:sha512), do: :usmHMAC384SHA512AuthProtocol

  defp priv_protocol(:des), do: :usmDESPrivProtocol
  defp priv_protocol(:aes128), do: :usmAesCfb128Protocol

  # Returns {ts, outcome, rtt_us}, where outcome is that of sync_get2, or
  # {:report, oid} for a report Detchi.Snmp.User passed on. sync_get2
  # runs in a task, so that the reports can come in while it waits.
  defp request(agent, oids, deadline, sync?) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 1)
    ts = System.os_time(:microsecond)
    started = System.monotonic_time(:microsecond)
    task = Task.async(fn -> :snmpm.sync_get2(@user, agent, oids, timeout: timeout) end)

    outcome = await(task, agent, started, sync?)
    # The task is done, or is not waited for any longer.
    Task.shutdown(task, :brutal_kill)

    case outcome do
      {:report, @usm_stats_not_in_time_windows, _} when sync? ->
        if System.monotonic_time(:millisecond) < deadline,
          do: request(agent, oids, deadline, false),
          else: {ts, {:error, {:timeout, nil}}, nil}

      {:report, oid, rtt_us} ->
        {ts, {:report, oid}, rtt_us}

      {:outcome, outcome, rtt_us} ->
        {ts, outcome, rtt_us}
    end
  end

  # Returns {:report, oid, rtt_us} for a report, or {:outcome, outcome,
  # rtt_us} for the rest of what sync_get2 returns.
  #
  # A report comes back to the request when it fails the security checks
  # of snmpm (one for a wrong key, or one at another security level), and
  # to Detchi.Snmp.User otherwise. snmpm calls the user through a process
  # of its own, so such a report is stamped a little late, and may come
  # after the request that follows. Reports stamped before the request
  # are not for it, and after a sync, one of usmStatsNotInTimeWindows is
  # taken as that of the first request: the time is right now. The RTT of
  # a report through the user includes the delay.
  defp await(task, agent, started, sync?) do
    ref = task.ref

    receive do
      {^ref, outcome} ->
        rtt_us = System.monotonic_time(:microsecond) - started

        case outcome do
          {:error, {:invalid_sec_info, _, {_, _, [{:varbind, oid, _, _, _} | _]}}} ->
            {:report, oid, rtt_us}

          _ ->
            {:outcome, outcome, rtt_us}
        end

      {:snmp_report, ^agent, oid, at} when at >= started ->
        if oid == @usm_stats_not_in_time_windows and not sync?,
          do: await(task, agent, started, sync?),
          else: {:report, oid, at - started}
    end
  end

  defp result({ts, outcome, rtt_us}, agent, line, snmp, timeout_ms) do
    line = Map.put(line, :ts, ts)

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

      {:report, oid} ->
        report(agent, oid, line, rtt_us, snmp)

      {:error, reason} ->
        raise "sync_get2 failed (#{describe(reason)})"
    end
  end

  defp report(agent, oid, line, rtt_us, snmp) do
    # The agent has another engine ID now; the next attempt discovers it.
    if oid == @usm_stats_unknown_engine_ids, do: forget_engine(agent)

    Map.merge(line, %{status: :error, rtt_us: rtt_us, error: {:snmp_report, oid}, snmp: snmp})
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
