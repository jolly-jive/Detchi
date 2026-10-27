defmodule Detchi.Snmp.User do
  @moduledoc """
  The `snmpm` user of Detchi (docs/basic-design.md, 5).

  Requests are made with `snmpm:sync_get2/4`, whose replies go to the
  caller; `snmpm` calls this module only for what comes otherwise:
  replies after the timeout, traps, informs, reports and errors. All are
  dropped. They run in the processes of `snmpm`, not of Detchi.

  Nothing is logged: the terms may hold a community.
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
  def handle_report(_target, _info, _data), do: :ignore
end
