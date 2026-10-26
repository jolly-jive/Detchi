defmodule Detchi.Tcp do
  @moduledoc """
  Connects to a TCP port and closes the connection (docs/basic-design.md,
  4.2).

  The RTT is the time of the handshake: from just before the SYN is sent
  to the SYN-ACK. Nothing is sent or read over the connection, and it is
  closed with a FIN.

  The kernel sends the SYN again after 1 second without a SYN-ACK, which
  cannot be turned off; with a timeout longer than that, the RTT may
  include the time to the SYN sent again.

  With `IP_RECVERR` (`IPV6_RECVERR`), an ICMP error about the SYN makes
  the connect fail at once, and is written with the type, the code and
  the sender, as for ICMP and UDP.
  """

  alias Detchi.Config.Probe
  alias Detchi.NetError

  @type result :: %{
          required(:ts) => integer(),
          required(:status) => :ok | :timeout | :refused | :unreachable,
          optional(:rtt_us) => non_neg_integer(),
          optional(:timeout_ms) => pos_integer(),
          optional(:error) => Detchi.Record.error()
        }

  @doc """
  Measures the RTT to the port of the probe at `addr` with one connect,
  as a probe's attempt.

  Returns the fields of the measurement line that depend on the result,
  with `ts` (system time in microseconds) taken as the attempt starts.
  Raises on failures that are not about the network (the socket cannot be
  opened, an unexpected errno), which the probe writes as `internal`.

  Options (for tests):

    * `:ttl`: the TTL or hop limit of the SYN.
  """
  @spec measure(:inet.ip_address(), Probe.t(), keyword()) :: result()
  def measure(addr, %Probe{port: port, timeout_ms: timeout_ms}, opts \\ []) do
    family = family(addr)

    socket =
      case :socket.open(family, :stream, :tcp) do
        {:ok, socket} -> socket
        {:error, errno} -> raise "cannot open a TCP socket (#{errno})"
      end

    try do
      NetError.recverr(socket, family)
      if ttl = opts[:ttl], do: :ok = :socket.setopt(socket, ttl_option(family), ttl)
      connect(socket, %{family: family, addr: addr, port: port}, timeout_ms)
    after
      :socket.close(socket)
    end
  end

  defp family({_, _, _, _}), do: :inet
  defp family({_, _, _, _, _, _, _, _}), do: :inet6

  defp ttl_option(:inet), do: {:ip, :ttl}
  defp ttl_option(:inet6), do: {:ipv6, :unicast_hops}

  defp connect(socket, sockaddr, timeout_ms) do
    ts = System.os_time(:microsecond)
    started = System.monotonic_time(:microsecond)
    outcome = :socket.connect(socket, sockaddr, timeout_ms)
    rtt_us = System.monotonic_time(:microsecond) - started

    case outcome do
      :ok ->
        %{ts: ts, status: :ok, rtt_us: rtt_us}

      {:error, :timeout} ->
        %{ts: ts, status: :timeout, timeout_ms: timeout_ms}

      # The local address is kept after the connect fails.
      {:error, errno} ->
        case :socket.sockname(socket) do
          {:ok, %{addr: local}} -> NetError.result(socket, errno, ts, local, rtt_us)
          {:error, _} -> NetError.errno_result(errno, ts)
        end
        |> rst(rtt_us)
    end
  end

  # A RST is not an ICMP error and leaves the error queue empty, but it
  # came from the network, so the time is an RTT.
  defp rst(%{error: {:errno, :econnrefused}} = result, rtt_us),
    do: Map.put(result, :rtt_us, rtt_us)

  defp rst(result, _rtt_us), do: result
end
