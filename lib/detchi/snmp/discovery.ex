defmodule Detchi.Snmp.Discovery do
  @moduledoc """
  Discovers the engine ID of an SNMPv3 agent (RFC 3414, 4;
  docs/basic-design.md, 5), which `snmpm` of OTP does not do.

  The request is a get-request of noAuthNoPriv with an empty engine ID,
  user name and varbind list, flagged reportable. The agent answers with
  a report of `usmStatsUnknownEngineIDs`, whose
  `msgAuthoritativeEngineID` is its engine ID. Neither carries a
  credential.
  """

  require Record

  @hrl "snmp/include/snmp_types.hrl"

  # snmp_types.hrl defines message under an ifdef; this is the v3 form.
  Record.defrecordp(:message, [:version, :vsn_hdr, :data])
  Record.defrecordp(:v3_hdr, Record.extract(:v3_hdr, from_lib: @hrl))
  Record.defrecordp(:scoped_pdu, :scopedPdu, Record.extract(:scopedPdu, from_lib: @hrl))
  Record.defrecordp(:pdu, Record.extract(:pdu, from_lib: @hrl))

  Record.defrecordp(
    :usm,
    :usmSecurityParameters,
    Record.extract(:usmSecurityParameters, from_lib: @hrl)
  )

  @usm 3
  @reportable 4
  @max_size 65_535

  @doc """
  Asks the agent at `addr` and `port` for its engine ID, waiting until
  `deadline` (monotonic time in milliseconds). Datagrams that are not the
  answer are skipped.

  Raises if the request cannot be sent.
  """
  @spec discover(:inet.ip_address(), :inet.port_number(), integer()) ::
          {:ok, charlist()} | :timeout
  def discover(addr, port, deadline) do
    # msgID and request-id are 0..2^31-1 (RFC 3412, RFC 3416).
    id = :rand.uniform(2_147_483_648) - 1
    {:ok, socket} = :gen_udp.open(0, [:binary, family(addr), active: false])

    try do
      case :gen_udp.send(socket, addr, port, request(id)) do
        :ok -> receive_reply(socket, addr, port, id, deadline)
        {:error, errno} -> raise "cannot send the engine ID discovery (#{errno})"
      end
    after
      :gen_udp.close(socket)
    end
  end

  defp family({_, _, _, _}), do: :inet
  defp family({_, _, _, _, _, _, _, _}), do: :inet6

  defp request(id) do
    params =
      :snmp_pdus.enc_usm_security_parameters(
        usm(
          msgAuthoritativeEngineID: [],
          msgAuthoritativeEngineBoots: 0,
          msgAuthoritativeEngineTime: 0,
          msgUserName: [],
          msgAuthenticationParameters: [],
          msgPrivacyParameters: []
        )
      )

    pdu =
      pdu(
        type: :"get-request",
        request_id: id,
        error_status: :noError,
        error_index: 0,
        varbinds: []
      )

    data = :snmp_pdus.enc_scoped_pdu(scoped_pdu(contextEngineID: [], contextName: [], data: pdu))

    hdr =
      v3_hdr(
        msgID: id,
        msgMaxSize: @max_size,
        msgFlags: [@reportable],
        msgSecurityModel: @usm,
        msgSecurityParameters: params
      )

    :snmp_pdus.enc_message_only(message(version: :"version-3", vsn_hdr: hdr, data: data))
  end

  defp receive_reply(socket, addr, port, id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    with true <- remaining > 0,
         {:ok, {^addr, ^port, packet}} <- :gen_udp.recv(socket, 0, remaining),
         {:ok, engine_id} <- engine_id(packet, id) do
      {:ok, engine_id}
    else
      false -> :timeout
      {:error, :timeout} -> :timeout
      {:error, errno} -> raise "cannot receive the engine ID discovery (#{errno})"
      # Another sender, or not the answer.
      _ -> receive_reply(socket, addr, port, id, deadline)
    end
  end

  defp engine_id(packet, id) do
    message(vsn_hdr: hdr) = :snmp_pdus.dec_message_only(:erlang.binary_to_list(packet))
    v3_hdr(msgID: ^id, msgSecurityParameters: params) = hdr

    usm(msgAuthoritativeEngineID: [_ | _] = engine_id) =
      :snmp_pdus.dec_usm_security_parameters(params)

    {:ok, engine_id}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
