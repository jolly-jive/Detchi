defmodule Detchi.Signals do
  @moduledoc """
  Stops `detchi run` on SIGHUP as on SIGTERM: `init:stop/0`, so that the
  `stop` lines are written (docs/basic-design.md, 7.9). Without it, the
  VM dies at once on SIGHUP.

  A handler of `erl_signal_server`, next to OTP's own, which stops on
  SIGTERM and ignores SIGHUP.

  SIGINT cannot be handled so: `os:set_signal/2` does not take it, and
  the break handler of the escript ends the VM at once.
  """

  @behaviour :gen_event

  require Logger

  @doc "Handles SIGHUP from now on."
  @spec install() :: :ok
  def install do
    :ok = :gen_event.add_handler(:erl_signal_server, __MODULE__, [])
    :ok = :os.set_signal(:sighup, :handle)
  end

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_event(:sighup, state) do
    # In the words of OTP's message for SIGTERM.
    Logger.notice("SIGHUP received - shutting down")
    :ok = :init.stop()
    {:ok, state}
  end

  def handle_event(_signal, state), do: {:ok, state}

  @impl true
  def handle_call(_request, state), do: {:ok, :ok, state}
end
