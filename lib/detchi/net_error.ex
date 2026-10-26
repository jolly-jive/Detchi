defmodule Detchi.NetError do
  @moduledoc """
  The status and the error of a measurement line from an errno of a
  socket (docs/basic-design.md, 4, 6.1), for the probes that use their
  own sockets: ICMP, TCP and UDP.

  With `IP_RECVERR` (`IPV6_RECVERR`), an ICMP error about what was sent
  makes the socket call fail with an errno, and the type, the code and
  the sender of the error are read from the error queue of the socket.
  Errnos without an ICMP error behind them are written as they are.
  """

  # sock_extended_err.ee_origin
  @origin_icmp 2
  @origin_icmp6 3

  @unreachable [:ehostunreach, :enetunreach, :ehostdown, :enetdown]

  @type icmp_error :: {non_neg_integer(), non_neg_integer(), :inet.ip_address()}

  @doc "Sets `IP_RECVERR` (`IPV6_RECVERR`) on a socket."
  @spec recverr(:socket.socket(), :inet | :inet6) :: :ok
  def recverr(socket, :inet), do: :ok = :socket.setopt(socket, {:ip, :recverr}, true)
  def recverr(socket, :inet6), do: :ok = :socket.setopt(socket, {:ipv6, :recverr}, true)

  @doc """
  Reads the ICMP error from the error queue of a socket, as the type, the
  code and the sender, or nil if there is none.

  The type and the code are read from struct sock_extended_err, not from
  the `value` OTP decodes, which turns them into atoms only for the ones
  it knows. The sender is the offender address after the struct.
  """
  @spec read(:socket.socket()) :: icmp_error() | nil
  def read(socket) do
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

  @doc """
  The fields of the line for an errno of a socket call made after the
  socket has its local address `local`: the ICMP error in the error queue
  if there is one, or the errno.

  An ICMP error the host made itself (a neighbor that does not answer
  ARP) comes from the local address; `rtt_us` is not an RTT then, and is
  left out.
  """
  @spec result(:socket.socket(), atom(), integer(), :inet.ip_address(), non_neg_integer()) ::
          map()
  def result(socket, errno, ts, local, rtt_us) do
    case read(socket) do
      nil ->
        errno_result(errno, ts)

      {type, code, from} = error ->
        result = %{ts: ts, status: icmp_status(error), error: {:icmp, type, code, from}}
        if from == local, do: result, else: Map.put(result, :rtt_us, rtt_us)
    end
  end

  @doc """
  The fields of the line for an errno without an ICMP error. Raises on an
  errno that is not about the network, which the probe writes as
  `internal`.
  """
  @spec errno_result(atom(), integer()) :: map()
  def errno_result(:econnrefused, ts),
    do: %{ts: ts, status: :refused, error: {:errno, :econnrefused}}

  def errno_result(errno, ts) when errno in @unreachable,
    do: %{ts: ts, status: :unreachable, error: {:errno, errno}}

  def errno_result(errno, _ts), do: raise("unexpected error of a socket (#{errno})")

  # Port Unreachable: type 3 code 3 in ICMPv4, type 1 code 4 in ICMPv6.
  defp icmp_status({3, 3, {_, _, _, _}}), do: :refused
  defp icmp_status({1, 4, {_, _, _, _, _, _, _, _}}), do: :refused
  defp icmp_status(_), do: :unreachable
end
