defmodule Detchi.TcpTest do
  use ExUnit.Case, async: true

  alias Detchi.Config.Probe
  alias Detchi.Tcp

  @probe %Probe{name: "ssh", protocol: :tcp, interval_ms: 60_000, timeout_ms: 1000, port: 22}

  # TEST-NET-1 (RFC 5737): sent through the default route, and nobody
  # answers.
  @silent {192, 0, 2, 1}

  describe "measure/3 on loopback" do
    test "an accepted connect is ok, with the RTT" do
      {listener, port} = listen({127, 0, 0, 1}, 8)
      before = System.os_time(:microsecond)

      assert %{ts: ts, status: :ok, rtt_us: rtt} =
               result = Tcp.measure({127, 0, 0, 1}, %{@probe | port: port})

      assert map_size(result) == 3
      assert ts >= before and ts <= System.os_time(:microsecond)
      assert rtt >= 0 and rtt < 1_000_000
      :socket.close(listener)
    end

    # With mirrored networking in WSL2, a closed port of 127.0.0.1 goes to
    # Windows and gets no RST; other loopback addresses get one.
    test "a RST is refused, with the errno and the RTT" do
      for addr <- [{127, 0, 0, 2}, {0, 0, 0, 0, 0, 0, 0, 1}] do
        port = closed_port(addr)

        assert %{status: :refused, error: {:errno, :econnrefused}, rtt_us: rtt} =
                 result = Tcp.measure(addr, %{@probe | port: port})

        assert map_size(result) == 4
        assert rtt >= 0
      end
    end

    # A listener whose accept queue is full drops the SYNs.
    test "no SYN-ACK is a timeout, after the timeout of the probe" do
      {listener, port} = listen({127, 0, 0, 1}, 0)
      {:ok, filler} = :socket.open(:inet, :stream, :tcp)
      :ok = :socket.connect(filler, %{family: :inet, addr: {127, 0, 0, 1}, port: port}, 1000)
      started = System.monotonic_time(:millisecond)

      assert %{ts: _, status: :timeout, timeout_ms: 300} =
               result = Tcp.measure({127, 0, 0, 1}, %{@probe | port: port, timeout_ms: 300})

      assert map_size(result) == 3
      assert System.monotonic_time(:millisecond) - started >= 300
      :socket.close(filler)
      :socket.close(listener)
    end
  end

  # These need a default route, and a first router that sends Time
  # Exceeded. Leave them out with `mix test --exclude network`.
  describe "measure/3 through the network" do
    @describetag :network

    test "no answer is a timeout" do
      assert %{status: :timeout, timeout_ms: 300} =
               Tcp.measure(@silent, %{@probe | timeout_ms: 300})
    end

    test "Time Exceeded is unreachable, with the type, the code, the router and the RTT" do
      assert %{status: :unreachable, error: {:icmp, 11, 0, from}, rtt_us: rtt} =
               Tcp.measure(@silent, @probe, ttl: 1)

      assert {_, _, _, _} = from
      assert rtt > 0
    end
  end

  defp listen(addr, backlog) do
    {:ok, listener} = :socket.open(:inet, :stream, :tcp)
    :ok = :socket.bind(listener, %{family: :inet, addr: addr, port: 0})
    :ok = :socket.listen(listener, backlog)
    {:ok, %{port: port}} = :socket.sockname(listener)
    {listener, port}
  end

  # A port that was just bound and closed, which nothing listens on.
  defp closed_port(addr) do
    family = if tuple_size(addr) == 4, do: :inet, else: :inet6
    {:ok, socket} = :socket.open(family, :stream, :tcp)
    :ok = :socket.bind(socket, %{family: family, addr: addr, port: 0})
    {:ok, %{port: port}} = :socket.sockname(socket)
    :socket.close(socket)
    port
  end
end
