# Records

English | [日本語](records.ja.md)

Detchi writes every measurement as one line of JSON, in one file per target per day. This document describes the files and the lines, and how to read them.

## Contents

- [Files](#files)
- [Lines](#lines)
- [Measurement lines](#measurement-lines)
- [Errors](#errors)
- [SNMP values](#snmp-values)
- [Event lines](#event-lines)
- [What the results mean](#what-the-results-mean)
- [Reading the records](#reading-the-records)

## Files

```
<data_dir>/<target>/<target>-YYYY-MM-DD.jsonl      today
<data_dir>/<target>/<target>-YYYY-MM-DD.jsonl.gz   past days (.jsonl.zst with zstd)
```

- The files are rotated daily: one directory per target, and one file per day. The file name holds the target name too, so a single downloaded file still tells what it is.
- The date is the local date of `ts`, by the `TZ` environment variable. A line always goes to the file of the date of its `ts`.
- Just after midnight, results of requests sent just before midnight can still arrive. The file of the previous day is kept open for the longest `timeout` of the target plus 10 seconds, and then closed and compressed.
- Compressed files keep the modification time of the `.jsonl`, that is, the time of the last line.
- Files are kept for `retention_days` days before today, by the date in the file name; older files are deleted. This covers targets that are no longer in the config too. Detchi scans `data_dir` at startup and every 24 hours.
- Detchi only touches files whose names follow the pattern above. Other files in `data_dir` are left alone.
- Detchi rotates, compresses, and deletes the files itself. Do not use logrotate on them.

A rough size: 100 probes every 60 seconds, at about 150 bytes a line, make about 20 MB a day, and a tenth of that with gzip.

## Lines

The files are [JSON Lines](https://jsonlines.org/): one JSON object per line. There are two kinds of lines:

- **Measurement lines**, with `protocol`: one line for each measurement, including failures. A timeout is a line too, so that a loss can be told from missing data.
- **Event lines**, with `event`: what happened to Detchi itself (start, stop, and so on), written in the file of each target.

```json
{"v":1,"ts":"2026-10-23T21:00:00.000000+09:00","target":"core1","event":"start","version":"0.1.0","config_hash":"sha256:0b3e44d9...","addr":"192.0.2.1"}
{"v":1,"ts":"2026-10-23T21:00:00.123456+09:00","target":"core1","probe":"ping","protocol":"icmp","addr":"192.0.2.1","status":"ok","rtt_us":1234}
{"v":1,"ts":"2026-10-23T21:01:00.123456+09:00","target":"core1","probe":"ping","protocol":"icmp","addr":"192.0.2.1","status":"timeout","timeout_ms":1000}
```

Every line has:

| Key | |
| --- | --- |
| `v` | The version of the schema, an integer. Now `1`. |
| `ts` | For a measurement, when it started (when the request was sent). For an event, when it happened. |
| `target` | The name of the target. |

- `ts` is RFC 3339 in local time, with microseconds (always 6 digits) and a numeric offset (always a number: `+00:00`, never `Z`).
- Keys come in a fixed order: `v`, `ts`, `target`, then `probe` or `event`, and so on, with the objects of a protocol (`udp`, `snmp`) last.
- `v` goes up only when the meaning or the type of a key changes, or a key is removed. Adding keys does not change `v`. Tools that read the records should ignore keys they do not know.
- Credentials never appear in the lines.

## Measurement lines

| Key | |
| --- | --- |
| `probe` | The name of the probe. |
| `protocol` | `icmp`, `tcp`, `udp`, or `snmp`. |
| `addr` | The IP address the request was sent to. Not written when the host name has never been looked up. IPv6 addresses are in the form of RFC 5952 (lowercase, zeros shortened). |
| `port` | The port, for TCP, UDP, and SNMP. |
| `status` | `ok`, `timeout`, `unreachable`, `refused`, or `error`. |
| `rtt_us` | The round-trip time in microseconds. Only when an answer came back from the network: see below. |
| `timeout_ms` | With `timeout`: how long Detchi waited. |
| `error` | With `unreachable`, `refused`, and `error`: why. See [Errors](#errors). |
| `udp` | UDP only: `{"service": "dns"}` and so on, the request that was sent. |
| `snmp` | SNMP only: `version`, `op` (`get`), and `varbinds` when the agent answered without an error. See [SNMP values](#snmp-values). |

`rtt_us` is written when something came back from the network: an answer, a TCP RST, an ICMP error from another host, or an SNMP `errorStatus`. It is not written when the error was made on the host of Detchi (an ICMP error from its own address, for example when ARP fails), nor for `unreachable` with an `errno`, because that time is not a round trip.

Examples:

```json
{"v":1,"ts":"2026-10-23T21:00:00.130000+09:00","target":"core1","probe":"dns","protocol":"udp","addr":"192.0.2.1","port":53,"status":"ok","rtt_us":2345,"udp":{"service":"dns"}}
{"v":1,"ts":"2026-10-23T21:00:00.135000+09:00","target":"core1","probe":"ssh","protocol":"tcp","addr":"192.0.2.1","port":22,"status":"refused","rtt_us":456,"error":{"reason":"errno","errno":"econnrefused"}}
{"v":1,"ts":"2026-10-23T21:00:00.137000+09:00","target":"core1","probe":"ntp","protocol":"udp","addr":"192.0.2.1","port":123,"status":"refused","rtt_us":95,"error":{"reason":"icmp","type":3,"code":3,"from":"192.0.2.1"},"udp":{"service":"ntp"}}
{"v":1,"ts":"2026-10-23T21:00:00.140000+09:00","target":"core1","probe":"sys","protocol":"snmp","addr":"192.0.2.1","port":161,"status":"timeout","timeout_ms":5000,"snmp":{"version":"v2c","op":"get"}}
{"v":1,"ts":"2026-10-23T21:00:00.865900+09:00","target":"nowhere","probe":"ping","protocol":"icmp","status":"error","error":{"reason":"resolve","errno":"nxdomain"}}
```

## Errors

`error` is an object with a `reason` and the keys of that reason. It holds only fixed words and numbers, never free text.

| `reason` | When | Keys | `status` |
| --- | --- | --- | --- |
| `errno` | An error of the socket without ICMP details (a TCP RST, no route on the host, and so on) | `errno` | `refused`, `unreachable` |
| `icmp` | An ICMP error came back for an ICMP, TCP, or UDP probe | `type`, `code`, `from` | `refused` (Port Unreachable), `unreachable` (the others) |
| `snmp` | The SNMP answer had a non-zero `errorStatus` | `error_status`, `error_index` | `error` |
| `snmp_report` | A report PDU of SNMPv3 came back (for v3, which is not supported yet) | `oid` | `error` |
| `resolve` | The host name has never been looked up | `errno` | `error` |
| `internal` | A failure Detchi did not expect. The details are in the log of Detchi. | | `error` |

```json
"error":{"reason":"errno","errno":"ehostunreach"}
"error":{"reason":"icmp","type":11,"code":0,"from":"192.0.2.254"}
"error":{"reason":"snmp","error_status":"genErr","error_index":2}
"error":{"reason":"resolve","errno":"nxdomain"}
"error":{"reason":"internal"}
```

- `errno` is the name Erlang gives the error (`econnrefused`, `ehostunreach`, `enetunreach`, `nxdomain`, and so on).
- `type` and `code` of `icmp` are the numbers of the ICMP message. ICMPv4 and ICMPv6 number them differently (Time Exceeded is 11 in ICMPv4 and 3 in ICMPv6); tell them apart by `addr`. Port Unreachable is type 3 code 3 in ICMPv4, and type 1 code 4 in ICMPv6.
- `from` of `icmp` is the address that sent the ICMP error: the target, a router on the way, a firewall, or the host of Detchi itself.
- `error_status` of `snmp` is the name in RFC 3416 (`tooBig`, `genErr`, and so on). `error_index` counts from 1, in the order of `oids` in the config; 0 points at no varbind. These lines have no `varbinds`.

## SNMP values

`varbinds` is a list, in the order of `oids` in the config:

```json
"snmp":{"version":"v2c","op":"get","varbinds":[
  {"oid":"1.3.6.1.2.1.1.3.0","type":"TimeTicks","value":123456},
  {"oid":"1.3.6.1.2.1.31.1.1.1.1.1","type":"OctetString","value":"Gi0/1"},
  {"oid":"1.3.6.1.2.1.2.2.1.6.1","type":"OctetString","hex":"001122aabbcc"},
  {"oid":"1.3.6.1.2.1.31.1.1.1.6.1","type":"Counter64","value":18446744073709551615},
  {"oid":"1.3.6.1.2.1.31.1.1.1.6.99","type":"noSuchInstance"}]}
```

(Broken over lines here to be read; in the files it is one line.)

| `type` | The value |
| --- | --- |
| `Integer`, `Counter32`, `Gauge32`, `TimeTicks`, `Counter64` | `value`: a number. `Integer` can be negative. |
| `OctetString` | `value`: a string, when the bytes are valid UTF-8 with no control characters other than tab, LF, and CR. Otherwise `hex`. |
| `ObjectIdentifier` | `value`: a dotted string. |
| `IpAddress` | `value`: a dotted string. `hex` when it is not 4 bytes long. |
| `Opaque` | `hex`, always. |
| `Null` | No value. |
| `noSuchObject`, `noSuchInstance`, `endOfMibView` | No value. The `status` of the line stays `ok`. |

- `hex` is lowercase hexadecimal without separators. Whether a value is text or bytes shows in the name of the key: `value` or `hex`. MAC addresses, and strings with a NUL at the end, are in `hex`.
- Values are raw. Counters are not turned into rates, and wraps and restarts of the agent are not handled. Put `sysUpTime.0` in the same probe to find restarts (see [Configuration](configuration.md#snmp-1)).
- `Counter64` is written as a JSON number, not a string. jq 1.7 and later keep large numbers exactly when they only pass them through or compare them, but calculations use doubles, which are exact only up to 2^53. A byte counter reaches 2^53 after about 8 days at 100 Gbps, 83 days at 10 Gbps, or 2.3 years at 1 Gbps. The error of a difference is at most 2048 even near 2^64, which hardly matters for rates; when exact values matter (equality, detecting wraps), use a language with big integers, such as Python.

## Event lines

| `event` | Keys | When |
| --- | --- | --- |
| `start` | `version`, `config_hash`, `addr` | Detchi started. |
| `file_opened` | `version`, `config_hash`, `addr` | A new file was opened at the change of the date (not at startup, where `start` is written). |
| `stop` | `abandoned` | Detchi stopped on SIGTERM or SIGHUP. `abandoned` is the number of requests whose results were not waited for. |
| `dropped` | `count`, `first_ts`, `last_ts` | Lines could not be written (the disk was full, for example), and now can. `count` lines with `ts` from `first_ts` to `last_ts` are missing. |
| `resolve_failed` | `host`, `error`, `addr` | Looking up the host name failed. `addr` is the address still in use; it is left out when the name has never been looked up. |
| `addr_changed` | `host`, `old`, `new` | The address of the host name changed. `old` is left out the first time a name is looked up. |
| `clock_stepped` | `offset_us` | The wall clock (`CLOCK_REALTIME` of Linux) jumped by 1 second or more: forward when positive, backward when negative. For example, when chrony sets the clock after Detchi started. |

```json
{"v":1,"ts":"2026-10-23T21:00:00.325614+09:00","target":"nowhere","event":"start","version":"0.1.0","config_hash":"sha256:8d11395f..."}
{"v":1,"ts":"2026-10-23T21:00:00.326895+09:00","target":"nowhere","event":"resolve_failed","host":"no-such-host.example","error":{"reason":"resolve","errno":"nxdomain"}}
{"v":1,"ts":"2026-10-23T21:05:00.000000+09:00","target":"core1","event":"addr_changed","host":"core1.example","old":"192.0.2.1","new":"192.0.2.9"}
{"v":1,"ts":"2026-10-23T22:00:03.926169+09:00","target":"core1","event":"stop","abandoned":1}
```

- `version` is the version of Detchi. `config_hash` is the config fingerprint of the target (see [Configuration](configuration.md#changing-the-config)).
- Every file starts with `start` or `file_opened`, so each file tells by itself which version of Detchi and which config wrote it.
- To read gaps:
  - `stop`, then `start`: Detchi was stopped (or restarted) in between.
  - `start` without a `stop` before it: Detchi crashed, or the host lost power. Detchi was not running in between.
  - `dropped`: Detchi was running, but could not write.
  - A target that was removed from the config has a `stop` as its last line.
- `resolve_failed` is written at every failed lookup. With the default `resolve_interval` of `5m`, a DNS outage of one day makes 288 lines.

## What the results mean

### ICMP

- `ok` when an Echo Reply comes back.
- `unreachable` or `refused` with an `icmp` error when a router or the target sends back an ICMP error.
- When ARP fails on the local network, the kernel itself makes a Host Unreachable after about 3 seconds, with `from` being the host of Detchi. With the default `timeout` of 1 second, the line is a `timeout` first.

### TCP

- `ok` when the connection is established (SYN-ACK). `rtt_us` is the time to connect.
- `refused` with `errno` `econnrefused` on a RST. A RST has no `from`, so it does not tell whether the target or a firewall sent it.
- Something on the way can answer in place of the target: a SYN proxy or a load balancer can send the SYN-ACK, a firewall the RST.
- With a `timeout` over 1 second, `rtt_us` can include a SYN sent again by the kernel. An `rtt_us` just over 1 second (or 3, 7, ... seconds) is likely one.

### UDP

- `ok` when any UDP answer comes back from the target. The contents are not checked: an NXDOMAIN of DNS or a Kiss-o'-Death of NTP is `ok` too.
- `refused` with an `icmp` error on Port Unreachable. A firewall (iptables `REJECT`, for example) can send it too; `from` tells who did.
- `rtt_us` includes the time the server takes to answer.

### SNMP

- The `status` is only `ok`, `timeout`, or `error`.
- No agent, a closed port, and a wrong community all give `timeout`: SNMP does not see ICMP errors.
- A request larger than the agent accepts is dropped by the agent, and gives `timeout`, not `tooBig`.
- Requests are not retried, so each `timeout` is one lost request.
- `rtt_us` includes the time inside the SNMP manager of Erlang (about 0.3 to 1.1 ms on loopback, against 0.15 ms of ICMP).

### All protocols

- Lines are written in the order the results arrive, not in the order of `ts`: a timeout is written after the results of requests sent later.
- `ts` comes from the wall clock, and `rtt_us` from a monotonic clock (`CLOCK_MONOTONIC` of Linux). A jump of the wall clock (see `clock_stepped`) moves `ts`, but not `rtt_us`.
- When the host of Detchi is busy (a Raspberry Pi under load, for example), the delay until Detchi handles an answer is included in `rtt_us`.

## Reading the records

The examples use [jq](https://jqlang.org/) 1.7. Compressed files can be read with `zcat` (or `zstdcat`).

Only the measurement lines:

```sh
jq -c 'select(.protocol)' core1-2026-10-23.jsonl
```

Only the event lines:

```sh
jq -c 'select(.event)' core1-2026-10-23.jsonl
```

The RTT of one probe in milliseconds, as CSV:

```sh
jq -r 'select(.probe == "ping" and .status == "ok") | [.ts, .rtt_us / 1000] | @csv' core1-2026-10-23.jsonl
```

The count of lines by status for one probe, over a month of compressed files:

```sh
zcat core1/core1-2026-10-*.jsonl.gz | jq -s 'map(select(.probe == "ping")) | group_by(.status) | map({status: .[0].status, n: length})'
```

The lines in the order of `ts`:

```sh
jq -sc 'sort_by(.ts)[]' core1-2026-10-23.jsonl
```

Sorting `ts` as strings is right only while the offset stays the same. Across a change of daylight saving time, convert the times first.
