defmodule Detchi.Icmp do
  @moduledoc """
  Sends one Echo and waits for the reply (docs/basic-design.md, 4).

  Each attempt opens an unprivileged ICMP socket (`SOCK_DGRAM`), connects
  it to the address, sends, waits and closes it. The kernel sets the
  identifier of the Echo to the port of the socket and passes on only the
  replies to it, and it computes the checksum, for ICMPv4 as well.

  With `IP_RECVERR` (`IPV6_RECVERR`), an ICMP error about the Echo makes
  the receive fail at once, and the type, the code and the sender of the
  error are read from the error queue of the socket.
  """

  alias Detchi.Config.Probe

  @echo_request_v4 8
  @echo_reply_v4 0
  @echo_request_v6 128
  @echo_reply_v6 129
  @payload_size 32

  # sock_extended_err.ee_origin
  @origin_icmp 2
  @origin_icmp6 3

  @unreachable [:ehostunreach, :enetunreach, :ehostdown, :enetdown]

  @type result :: %{
          required(:ts) => integer(),
          required(:status) => :ok | :timeout | :refused | :unreachable,
          optional(:rtt_us) => non_neg_integer(),
          optional(:timeout_ms) => pos_integer(),
          optional(:error) => Detchi.Record.error()
        }

  @doc """
  Measures the RTT to `addr` with one Echo, as a probe's attempt.

  Returns the fields of the measurement line that depend on the result,
  with `ts` (system time in microseconds) taken as the attempt starts.
  Raises on failures that are not about the network (the socket cannot be
  opened, an unexpected errno), which the probe writes as `internal`.

  Options (for tests):

    * `:ttl`: the TTL or hop limit of the Echo.
  """
  @spec measure(:inet.ip_address(), Probe.t(), keyword()) :: result()
  def measure(addr, %Probe{timeout_ms: timeout_ms}, opts \\ []) do
    family = family(addr)

    socket =
      case open(family) do
        {:ok, socket} -> socket
        {:error, errno} -> raise "cannot open an ICMP socket (#{errno})"
      end

    try do
      :ok = :socket.setopt(socket, recverr(family), true)
      if ttl = opts[:ttl], do: :ok = :socket.setopt(socket, ttl_option(family), ttl)
      echo(socket, family, addr, timeout_ms)
    after
      :socket.close(socket)
    end
  end

  @doc """
  Checks that ICMP sockets of `family` can be opened, as `detchi run`
  does before it starts (docs/basic-design.md, 4).
  """
  @spec check(:inet | :inet6) :: :ok | {:error, atom()}
  def check(family) do
    with {:ok, socket} <- open(family), do: :socket.close(socket)
  end

  @doc """
  The address families the ICMP probes of the targets use: IPv6 for a
  target whose family is `ipv6` or whose host is an IPv6 address, IPv4
  for the others (`auto` looks up A first).
  """
  @spec families([Detchi.Config.Target.t()]) :: [:inet | :inet6]
  def families(targets) do
    targets
    |> Enum.filter(fn target -> Enum.any?(target.probes, &(&1.protocol == :icmp)) end)
    |> Enum.map(fn
      %{address: {_, _, _, _, _, _, _, _}} -> :inet6
      %{address: nil, family: :ipv6} -> :inet6
      _ -> :inet
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Describes why an ICMP socket cannot be opened, for `detchi run`."
  @spec describe(:inet | :inet6, atom()) :: String.t()
  def describe(family, errno) when errno in [:eacces, :eperm],
    do:
      "cannot open an #{name(family)} socket (#{errno}); " <>
        "net.ipv4.ping_group_range does not include the groups of this user"

  def describe(family, errno), do: "cannot open an #{name(family)} socket (#{errno})"

  defp name(:inet), do: "ICMP"
  defp name(:inet6), do: "ICMPv6"

  defp family({_, _, _, _}), do: :inet
  defp family({_, _, _, _, _, _, _, _}), do: :inet6

  defp open(:inet), do: :socket.open(:inet, :dgram, :icmp)
  defp open(:inet6), do: :socket.open(:inet6, :dgram, :"ipv6-icmp")

  defp recverr(:inet), do: {:ip, :recverr}
  defp recverr(:inet6), do: {:ipv6, :recverr}

  defp ttl_option(:inet), do: {:ip, :ttl}
  defp ttl_option(:inet6), do: {:ipv6, :unicast_hops}

  defp echo_types(:inet), do: {@echo_request_v4, @echo_reply_v4}
  defp echo_types(:inet6), do: {@echo_request_v6, @echo_reply_v6}

  defp echo(socket, family, addr, timeout_ms) do
    {request, reply} = echo_types(family)
    seq = :rand.uniform(0x10000) - 1
    payload = :rand.bytes(@payload_size)
    # The identifier and the checksum are left to the kernel.
    packet = <<request, 0, 0::16, 0::16, seq::16, payload::binary>>
    expected = {reply, seq, payload}

    ts = System.os_time(:microsecond)

    with :ok <- :socket.connect(socket, %{family: family, addr: addr, port: 0}),
         {:ok, %{addr: local}} <- :socket.sockname(socket),
         started = System.monotonic_time(:microsecond),
         :ok <- :socket.send(socket, packet) do
      wait = %{
        socket: socket,
        expected: expected,
        local: local,
        ts: ts,
        started: started,
        deadline: started + timeout_ms * 1000,
        timeout_ms: timeout_ms
      }

      receive_reply(wait)
    else
      {:error, errno} -> errno_result(errno, ts)
    end
  end

  defp receive_reply(wait) do
    case wait.deadline - System.monotonic_time(:microsecond) do
      remaining when remaining <= 0 ->
        timeout(wait)

      remaining ->
        case :socket.recv(wait.socket, 0, div(remaining + 999, 1000)) do
          {:ok, packet} ->
            now = System.monotonic_time(:microsecond)

            if reply?(packet, wait.expected),
              do: %{ts: wait.ts, status: :ok, rtt_us: now - wait.started},
              else: receive_reply(wait)

          {:error, :timeout} ->
            timeout(wait)

          {:error, errno} ->
            now = System.monotonic_time(:microsecond)

            case icmp_error(wait.socket) do
              nil -> errno_result(errno, wait.ts)
              error -> icmp_result(error, wait, now - wait.started)
            end
        end
    end
  end

  defp timeout(wait), do: %{ts: wait.ts, status: :timeout, timeout_ms: wait.timeout_ms}

  defp reply?(
         <<type, _code, _checksum::16, _id::16, seq::16, payload::binary>>,
         {type, seq, payload}
       ),
       do: true

  defp reply?(_packet, _expected), do: false

  # The type and the code are read from struct sock_extended_err, not from
  # the `value` OTP decodes, which turns them into atoms only for the ones
  # it knows. The sender is the offender address after the struct.
  defp icmp_error(socket) do
    case :socket.recvmsg(socket, 0, 0, [:errqueue], 0) do
      {:ok, %{ctrl: ctrl}} ->
        Enum.find_value(ctrl, fn
          %{
            type: :recverr,
            data: <<_errno::32-native, origin, type, code, _::binary>>,
            value: %{offender: %{addr: from}}
          }
          when origin in [@origin_icmp, @origin_icmp6] ->
            {type, code, from}

          _ ->
            nil
        end)

      {:error, _} ->
        nil
    end
  end

  # An error the host made itself (a neighbor that does not answer ARP)
  # comes from the local address; the time is not an RTT then.
  defp icmp_result({type, code, from} = error, wait, rtt_us) do
    result = %{ts: wait.ts, status: icmp_status(error), error: {:icmp, type, code, from}}
    if from == wait.local, do: result, else: Map.put(result, :rtt_us, rtt_us)
  end

  # Port Unreachable: type 3 code 3 in ICMPv4, type 1 code 4 in ICMPv6.
  defp icmp_status({3, 3, {_, _, _, _}}), do: :refused
  defp icmp_status({1, 4, {_, _, _, _, _, _, _, _}}), do: :refused
  defp icmp_status(_), do: :unreachable

  defp errno_result(:econnrefused, ts),
    do: %{ts: ts, status: :refused, error: {:errno, :econnrefused}}

  defp errno_result(errno, ts) when errno in @unreachable,
    do: %{ts: ts, status: :unreachable, error: {:errno, errno}}

  defp errno_result(errno, _ts), do: raise("unexpected error of an ICMP socket (#{errno})")
end
