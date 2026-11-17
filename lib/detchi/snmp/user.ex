defmodule Detchi.Snmp.User do
  @moduledoc """
  The `snmpm` user of Detchi (docs/basic-design.md, 5).

  Requests are made with `snmpm:sync_get2/4`, whose replies go to the
  caller; `snmpm` calls this module only for what comes otherwise:
  replies after the timeout, traps, informs, reports and errors. These
  run in the processes of `snmpm`, not of Detchi.

  Reports are passed on to the attempts waiting on the target, as
  `{:snmp_report, target, oid, monotonic_us}` with the OID of the first
  varbind: `snmpm` gives the reports that pass its security checks to
  this module, not to the request (docs/basic-design.md, 5). The rest is
  dropped.

  Nothing is logged: the terms may hold a credential.
  """

  @behaviour :snmpm_user

  @impl true
  def handle_error(_req_id, _reason, _data), do: :ignore

  @impl true
  def handle_agent(_domain, _address, _type, _info, _data), do: :ignore

  @impl true
  def handle_pdu(_target, _req_id, _response, _data), do: :ignore

  @impl true
  def handle_trap(_target, _info, _data), do: :ignore

  @impl true
  def handle_inform(_target, _info, _data), do: :ignore

  @impl true
  def handle_report(target, {_status, _index, [{:varbind, oid, _, _, _} | _]}, _data) do
    at = System.monotonic_time(:microsecond)
    for pid <- Detchi.Snmp.waiters(target), do: send(pid, {:snmp_report, target, oid, at})
    :ignore
  end

  def handle_report(_target, _info, _data), do: :ignore
end
