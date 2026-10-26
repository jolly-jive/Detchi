defmodule Detchi.Udp do
  @moduledoc """
  Sends one request of a service over UDP and waits for a reply
  (docs/basic-design.md, 4.1), as NexPinger v1.4.0 does.

  The request is one that servers of the service always answer. Any
  datagram that comes back is a reply, whatever it holds: the point is
  whether the request gets there.

  Each attempt opens a socket and connects it to the address and the
  port, so the kernel drops datagrams from other senders, and a late
  reply to an earlier attempt cannot be taken for this one. The request
  is not sent again.

  With `IP_RECVERR` (`IPV6_RECVERR`), an ICMP error about the request
  makes the receive fail at once, and is written with the type, the code
  and the sender, as for ICMP and TCP. Port Unreachable is `refused`.
  """

  alias Detchi.Config.Probe
  alias Detchi.NetError

  # RFC 9000, 15: versions of the form 0x?a?a?a?a are reserved, so a
  # server answers with a Version Negotiation.
  @quic_version 0x1A2A3A4A
  # RFC 9000, 14.1: servers drop Initial packets smaller than this.
  @quic_size 1200

  @type service :: :dns | :ntp | :quic

  @type result :: %{
          required(:ts) => integer(),
          required(:status) => :ok | :timeout | :refused | :unreachable,
          optional(:rtt_us) => non_neg_integer(),
          optional(:timeout_ms) => pos_integer(),
          optional(:error) => Detchi.Record.error()
        }

  @doc """
  Measures the RTT to the port of the probe at `addr` with one request of
  the service of the probe, as a probe's attempt.

  Returns the fields of the measurement line that depend on the result,
  with `ts` (system time in microseconds) taken just before the request
  is sent. Raises on failures that are not about the network (the socket
  cannot be opened, an unexpected errno), which the probe writes as
  `internal`.

  Options (for tests):

    * `:ttl`: the TTL or hop limit of the request.
  """
  @spec measure(:inet.ip_address(), Probe.t(), keyword()) :: result()
  def measure(addr, %Probe{port: port, service: service, timeout_ms: timeout_ms}, opts \\ []) do
    family = family(addr)

    socket =
      case :socket.open(family, :dgram, :udp) do
        {:ok, socket} -> socket
        {:error, errno} -> raise "cannot open a UDP socket (#{errno})"
      end

    try do
      NetError.recverr(socket, family)
      if ttl = opts[:ttl], do: :ok = :socket.setopt(socket, ttl_option(family), ttl)
      exchange(socket, %{family: family, addr: addr, port: port}, request(service), timeout_ms)
    after
      :socket.close(socket)
    end
  end

  @doc """
  The request sent for a service:

    * `dns`: a query of `. SOA`, with RD=0 and no EDNS, and a random ID.
    * `ntp`: an NTPv4 client request (mode 3), with a random Transmit
      Timestamp, which some servers require.
    * `quic`: a long header Initial of a reserved version, with random
      connection IDs, padded with zeros to 1200 bytes.
  """
  @spec request(service()) :: binary()
  def request(:dns) do
    # ID, flags, QDCOUNT, ANCOUNT, NSCOUNT, ARCOUNT; the root name, QTYPE
    # SOA, QCLASS IN.
    <<:rand.uniform(0x10000) - 1::16, 0::16, 1::16, 0::16, 0::16, 0::16, 0, 6::16, 1::16>>
  end

  def request(:ntp), do: <<0x23, 0::size(39)-unit(8), :rand.bytes(8)::binary>>

  def request(:quic) do
    header = <<0xC0, @quic_version::32, 8, :rand.bytes(8)::binary, 8, :rand.bytes(8)::binary>>
    <<header::binary, 0::size(@quic_size - byte_size(header))-unit(8)>>
  end

  defp family({_, _, _, _}), do: :inet
  defp family({_, _, _, _, _, _, _, _}), do: :inet6

  defp ttl_option(:inet), do: {:ip, :ttl}
  defp ttl_option(:inet6), do: {:ipv6, :unicast_hops}

  defp exchange(socket, sockaddr, request, timeout_ms) do
    # Nothing is sent if the connect fails; ts is then the time of the
    # connect.
    ts = System.os_time(:microsecond)

    with :ok <- :socket.connect(socket, sockaddr),
         {:ok, %{addr: local}} <- :socket.sockname(socket) do
      send_request(socket, request, local, timeout_ms)
    else
      {:error, errno} -> NetError.errno_result(errno, ts)
    end
  end

  defp send_request(socket, request, local, timeout_ms) do
    ts = System.os_time(:microsecond)
    started = System.monotonic_time(:microsecond)

    with :ok <- :socket.send(socket, request) do
      outcome = :socket.recv(socket, 0, timeout_ms)
      rtt_us = System.monotonic_time(:microsecond) - started

      case outcome do
        {:ok, _reply} -> %{ts: ts, status: :ok, rtt_us: rtt_us}
        {:error, :timeout} -> %{ts: ts, status: :timeout, timeout_ms: timeout_ms}
        {:error, errno} -> NetError.result(socket, errno, ts, local, rtt_us)
      end
    else
      {:error, errno} -> NetError.errno_result(errno, ts)
    end
  end
end
