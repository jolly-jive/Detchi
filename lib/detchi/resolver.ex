defmodule Detchi.Resolver do
  @moduledoc """
  Holds the address of one target (docs/basic-design.md, 3.1, 7.6).

  The first lookup is done in `handle_continue/2`, so that a host name
  that does not resolve does not hold up the other targets. Its result
  goes to the Writer as `start` with a call, and only then to the
  address table, so that `start` comes before any measurement. A host
  that is an IP address is not looked up.

  A host name is looked up again every `resolve_interval_ms`. On a
  failure the address in use is kept, and `resolve_failed` is written.
  While the name has never resolved, the lookup is retried sooner: from
  10 seconds, doubling up to `resolve_interval_ms`.

  The Resolver does not trap exits, so it stops at once on shutdown,
  even in the middle of a lookup.
  """

  use GenServer

  alias Detchi.{Addresses, Writer}
  alias Detchi.Config.Target

  @first_retry_ms 10_000
  @lookup_timeout_ms 5_000

  @type lookup :: (charlist(), :inet | :inet6, timeout() ->
                     {:ok, [:inet.ip_address()]} | {:error, atom()})

  @type option ::
          {:target, Target.t()}
          | {:writer, GenServer.server()}
          | {:resolve_interval_ms, pos_integer()}
          | {:name, GenServer.name()}
          | {:table, atom()}
          | {:register, (:inet.ip_address() -> :ok)}
          | {:lookup, lookup()}
          | {:first_retry_ms, pos_integer()}

  @doc """
  Starts a Resolver.

  Options:

    * `:target` (required): the target, as in the config.
    * `:writer` (required): the Writer of the target.
    * `:resolve_interval_ms` (required): how often a host name is looked
      up again.
    * `:name`: the name of the process.
    * `:table`: the address table. Defaults to `Detchi.Addresses`.
    * `:register`: called with an address before it goes to the table,
      to register the target in `snmpm`. Does nothing for now.
    * `:lookup`: looks up a host name, as `:inet.getaddrs/3`. For tests.
    * `:first_retry_ms`: the first wait for retries while the host name
      has never resolved. For tests.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    %Target{} = target = Keyword.fetch!(opts, :target)
    interval_ms = Keyword.fetch!(opts, :resolve_interval_ms)

    state = %{
      target: target,
      writer: Keyword.fetch!(opts, :writer),
      interval_ms: interval_ms,
      table: Keyword.get(opts, :table, Addresses),
      register: Keyword.get(opts, :register, fn _ -> :ok end),
      lookup: Keyword.get(opts, :lookup, &:inet.getaddrs/3),
      # nil while the host name has never resolved.
      addr: nil,
      # The next wait while the host name has never resolved.
      retry_ms: min(Keyword.get(opts, :first_retry_ms, @first_retry_ms), interval_ms)
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, %{target: %Target{address: address}} = state)
      when address != nil do
    state.register.(address)
    :ok = Writer.start(state.writer, address)
    Addresses.put(state.table, state.target.name, address)
    {:noreply, %{state | addr: address}}
  end

  def handle_continue(:start, state) do
    case resolve(state) do
      {:ok, [addr | _]} ->
        state.register.(addr)
        :ok = Writer.start(state.writer, addr)
        Addresses.put(state.table, state.target.name, addr)
        {:noreply, schedule(%{state | addr: addr})}

      {:error, errno} ->
        :ok = Writer.start(state.writer, nil)
        {:noreply, failed(state, errno)}
    end
  end

  @impl true
  def handle_info(:resolve, state) do
    case resolve(state) do
      {:ok, addrs} ->
        if state.addr in addrs do
          {:noreply, schedule(state)}
        else
          {:noreply, schedule(change(state, hd(addrs)))}
        end

      {:error, errno} ->
        {:noreply, failed(state, errno)}
    end
  end

  defp change(state, addr) do
    state.register.(addr)

    Writer.event(state.writer, :addr_changed, %{
      host: state.target.host,
      old: state.addr,
      new: addr
    })

    Addresses.put(state.table, state.target.name, addr)
    %{state | addr: addr}
  end

  defp failed(state, errno) do
    Writer.event(state.writer, :resolve_failed, %{
      host: state.target.host,
      error: {:resolve, errno},
      addr: state.addr
    })

    case state.addr do
      nil ->
        Addresses.put(state.table, state.target.name, {:unresolved, errno})
        Process.send_after(self(), :resolve, state.retry_ms)
        %{state | retry_ms: min(state.retry_ms * 2, state.interval_ms)}

      _ ->
        schedule(state)
    end
  end

  defp schedule(state) do
    Process.send_after(self(), :resolve, state.interval_ms)
    state
  end

  # `auto` looks up A, and AAAA only if there is no A (docs/basic-design.md,
  # 7.6). The native lookup gives nxdomain also for a name without A.
  defp resolve(state) do
    host = String.to_charlist(state.target.host)

    case state.target.family do
      :ipv4 ->
        lookup(state, host, :inet)

      :ipv6 ->
        lookup(state, host, :inet6)

      :auto ->
        case lookup(state, host, :inet) do
          {:error, :nxdomain} -> lookup(state, host, :inet6)
          result -> result
        end
    end
  end

  defp lookup(state, host, family) do
    case state.lookup.(host, family, @lookup_timeout_ms) do
      {:ok, [_ | _]} = result -> result
      {:ok, []} -> {:error, :nxdomain}
      {:error, errno} -> {:error, errno}
    end
  end
end
