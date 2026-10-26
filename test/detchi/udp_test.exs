defmodule Detchi.UdpTest do
  use ExUnit.Case, async: true

  alias Detchi.Config.Probe
  alias Detchi.Udp

  @probe %Probe{
    name: "dns",
    protocol: :udp,
    interval_ms: 60_000,
    timeout_ms: 1000,
    port: 53,
    service: :dns
  }

  # TEST-NET-1 (RFC 5737): sent through the default route, and nobody
  # answers.
  @silent {192, 0, 2, 1}

  describe "request/1" do
    test "dns is a query of . SOA with RD=0 and no EDNS" do
      assert <<_id::16, 0::16, 1::16, 0::16, 0::16, 0::16, 0, 6::16, 1::16>> =
               request = Udp.request(:dns)

      assert byte_size(request) == 17
    end

    test "ntp is a client request of version 4 with a Transmit Timestamp" do
      assert <<0x23, zeros::binary-size(39), transmit::binary-size(8)>> =
               request = Udp.request(:ntp)

      assert byte_size(request) == 48
      assert zeros == <<0::size(39)-unit(8)>>
      assert transmit != Udp.request(:ntp) |> binary_part(40, 8)
    end

    test "quic is an Initial of a reserved version, padded to 1200 bytes" do
      assert <<0xC0, 0x1A2A3A4A::32, 8, dcid::binary-size(8), 8, scid::binary-size(8),
               padding::binary>> = request = Udp.request(:quic)

      assert byte_size(request) == 1200
      assert dcid != scid
      assert padding == <<0::size(1200 - 23)-unit(8)>>
    end
  end

  describe "measure/3 on loopback" do
    test "a reply is ok, with the RTT, whatever it holds" do
      for service <- [:dns, :ntp, :quic] do
        {server, port} = open({127, 0, 0, 1})
        task = Task.async(fn -> answer(server, "not a reply of #{service}") end)
        before = System.os_time(:microsecond)

        assert %{ts: ts, status: :ok, rtt_us: rtt} =
                 result =
                 Udp.measure({127, 0, 0, 1}, %{@probe | port: port, service: service})

        assert map_size(result) == 3
        assert ts >= before and ts <= System.os_time(:microsecond)
        assert rtt >= 0 and rtt < 1_000_000
        assert byte_size(Task.await(task)) == byte_size(Udp.request(service))
        :socket.close(server)
      end
    end

    test "IPv6 is answered too" do
      {server, port} = open({0, 0, 0, 0, 0, 0, 0, 1})
      task = Task.async(fn -> answer(server, "") end)

      assert %{status: :ok, rtt_us: _} =
               Udp.measure({0, 0, 0, 0, 0, 0, 0, 1}, %{@probe | port: port})

      Task.await(task)
      :socket.close(server)
    end

    # The kernel drops datagrams from other senders on a connected socket.
    test "a reply from another port is not taken" do
      {server, port} = open({127, 0, 0, 1})
      {other, _} = open({127, 0, 0, 1})

      task =
        Task.async(fn ->
          {:ok, {source, _}} = :socket.recvfrom(server, 0, 1000)
          :ok = :socket.sendto(other, "reply", source)
        end)

      assert %{status: :timeout, timeout_ms: 300} =
               Udp.measure({127, 0, 0, 1}, %{@probe | port: port, timeout_ms: 300})

      Task.await(task)
      :socket.close(other)
      :socket.close(server)
    end

    test "no reply is a timeout, after the timeout of the probe" do
      {server, port} = open({127, 0, 0, 1})
      started = System.monotonic_time(:millisecond)

      assert %{ts: _, status: :timeout, timeout_ms: 300} =
               result = Udp.measure({127, 0, 0, 1}, %{@probe | port: port, timeout_ms: 300})

      assert map_size(result) == 3
      assert System.monotonic_time(:millisecond) - started >= 300
      :socket.close(server)
    end

    # The Port Unreachable comes from 127.0.0.2, not from the local
    # address 127.0.0.1, so it has an RTT.
    test "Port Unreachable is refused, with the type, the code, the sender and the RTT" do
      port = closed_port({127, 0, 0, 2})

      assert %{status: :refused, error: {:icmp, 3, 3, {127, 0, 0, 2}}, rtt_us: rtt} =
               result = Udp.measure({127, 0, 0, 2}, %{@probe | port: port})

      assert map_size(result) == 4
      assert rtt >= 0
    end

    # From the local address, the error is taken as made by the host
    # itself, and has no RTT (docs/basic-design.md, 6.1).
    test "Port Unreachable from the local address has no RTT" do
      for addr <- [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
        port = closed_port(addr)
        {type, code} = if tuple_size(addr) == 4, do: {3, 3}, else: {1, 4}

        assert %{status: :refused, error: {:icmp, ^type, ^code, ^addr}} =
                 result = Udp.measure(addr, %{@probe | port: port})

        assert map_size(result) == 3
      end
    end
  end

  # These need a default route, and a first router that sends Time
  # Exceeded. Leave them out with `mix test --exclude network`.
  describe "measure/3 through the network" do
    @describetag :network

    test "no answer is a timeout" do
      assert %{status: :timeout, timeout_ms: 300} =
               Udp.measure(@silent, %{@probe | timeout_ms: 300})
    end

    test "Time Exceeded is unreachable, with the type, the code, the router and the RTT" do
      assert %{status: :unreachable, error: {:icmp, 11, 0, from}, rtt_us: rtt} =
               Udp.measure(@silent, @probe, ttl: 1)

      assert {_, _, _, _} = from
      assert rtt > 0
    end
  end

  defp open(addr) do
    family = family(addr)
    {:ok, socket} = :socket.open(family, :dgram, :udp)
    :ok = :socket.bind(socket, %{family: family, addr: addr, port: 0})
    {:ok, %{port: port}} = :socket.sockname(socket)
    {socket, port}
  end

  # Answers one request with `reply`, and returns the request.
  defp answer(server, reply) do
    {:ok, {source, request}} = :socket.recvfrom(server, 0, 1000)
    :ok = :socket.sendto(server, reply, source)
    request
  end

  # A port that was just bound and closed, which nothing listens on. It is
  # bound by number: with mirrored networking in WSL2, the first datagram
  # to a port the kernel chose and that was just closed gets no Port
  # Unreachable.
  defp closed_port(addr) do
    family = family(addr)
    {:ok, socket} = :socket.open(family, :dgram, :udp)
    port = 20_000 + :rand.uniform(10_000)

    case :socket.bind(socket, %{family: family, addr: addr, port: port}) do
      :ok ->
        :socket.close(socket)
        port

      {:error, :eaddrinuse} ->
        :socket.close(socket)
        closed_port(addr)
    end
  end

  defp family(addr) when tuple_size(addr) == 4, do: :inet
  defp family(_addr), do: :inet6
end
