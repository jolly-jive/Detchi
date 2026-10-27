# Configuration

English | [日本語](configuration.ja.md)

Detchi reads one YAML file: `$DETCHI_CONFIG`, or `/etc/detchi/detchi.yml` when it is not set.

## Contents

- [An example](#an-example)
- [Checking the file](#checking-the-file)
- [Top level](#top-level)
- [defaults](#defaults)
- [credentials](#credentials)
- [targets](#targets)
- [probes](#probes)
- [Names](#names)
- [Durations](#durations)
- [Reusing probes with anchors](#reusing-probes-with-anchors)
- [Changing the config](#changing-the-config)
- [Credentials and safety](#credentials-and-safety)

## An example

```yaml
data_dir: /var/lib/detchi
retention_days: 1827
compression: gzip            # gzip | zstd
resolve_interval: 5m

defaults:                    # for probes that leave them out
  interval: 60s
  timeout: 1s                # ICMP, TCP, UDP
  snmp_timeout: 5s           # SNMP

credentials:
  campus-v2c: { version: v2c, community: "..." }

targets:
  - name: core1
    host: 192.0.2.1          # an IP address or a host name
    family: auto             # auto | ipv4 | ipv6
    snmp:
      credential: campus-v2c
      port: 161
    probes:
      - name: ping
        protocol: icmp
      - name: ssh
        protocol: tcp
        port: 22
      - name: dns
        protocol: udp
        service: dns         # dns | ntp | quic
      - name: if-uplink
        protocol: snmp
        interval: 300s
        oids:                # taken in one request
          - "1.3.6.1.2.1.1.3.0"           # sysUpTime.0
          - "1.3.6.1.2.1.31.1.1.1.6.1"    # ifHCInOctets.1
          - "1.3.6.1.2.1.31.1.1.1.10.1"   # ifHCOutOctets.1
```

## Checking the file

The file is checked strictly. Detchi does not start when:

- a key is unknown (a typo would otherwise drop a probe without a word, and stay unnoticed for years),
- a key appears twice in the same mapping,
- the file holds more than one YAML document,
- a value has the wrong type (an OID written as `1.3` is a number, not a string; a duration without a unit),
- a required key is missing, or a list that must not be empty is empty.

All the errors in the file are reported, not only the first, in the form `<file>:<line>:<column>: error: <path>: <message>`:

```
$ detchi check-config
/etc/detchi/detchi.yml:7:19: error: targets[0].probes[0].interval: must be a positive duration with a unit (ms, s, m, h), such as "60s"
/etc/detchi/detchi.yml:8:9: error: targets[0].probes[1]: missing key "port"
/etc/detchi/detchi.yml:10:9: error: targets[0].probes[1]: unknown key
/etc/detchi/detchi.yml: 3 errors
```

The messages never quote the file, not even the name of an unknown key, because a misplaced credential can end up in a key (`community:secret`, without the space after `:`, is a key). Go to the line and column to see what is wrong.

`detchi check-config` reads only the file: it does not look up host names, nor check that `data_dir` exists or is writable.

| Result | Output | Exit status |
| --- | --- | --- |
| No errors | Warnings, then `<file>: ok (N targets, M probes)`, on stdout | 0 |
| Errors | The errors, then `<file>: N errors`, on stderr | 1 |
| Wrong usage | The usage, on stderr | 2 |

Warnings do not stop Detchi. `detchi run` writes the same warnings to its log at startup.

`detchi check-config --fingerprints` also prints, for each target, its config fingerprint and the canonical JSON the fingerprint is taken of (see [Changing the config](#changing-the-config)).

## Top level

| Key | Default | |
| --- | --- | --- |
| `data_dir` | `/var/lib/detchi` | Where the records go. An absolute path. |
| `retention_days` | `1827` (5 years) | How many days to keep, before today. A positive integer. With `1`, today and yesterday are kept. |
| `compression` | `gzip` | How past days are compressed: `gzip` or `zstd`. |
| `resolve_interval` | `5m` | How often host names are looked up again. A [duration](#durations). |
| `defaults` | | See [defaults](#defaults). |
| `credentials` | | See [credentials](#credentials). |
| `targets` | (required) | The devices to measure. Must not be empty. |

Keys that start with `x-` are ignored at the top level, so that they can hold YAML anchors (see [Reusing probes with anchors](#reusing-probes-with-anchors)).

`gzip` files can be read with `zcat` and `zgrep` almost anywhere. `zstd` files need the `zstd` command (`zstdcat`, `zstdgrep`) where they are read. Changing `compression` does not recompress the files already compressed; they are kept until `retention_days` is over.

## defaults

The values for probes that do not set them.

| Key | Default | Applies to |
| --- | --- | --- |
| `interval` | `60s` | All probes |
| `timeout` | `1s` | ICMP, TCP, UDP |
| `snmp_timeout` | `5s` | SNMP |

`timeout` does not apply to SNMP, so that setting it in one place does not shorten the SNMP timeouts too. A `timeout` set on a probe wins, whatever the protocol.

## credentials

Named SNMP credentials, used by targets through `snmp.credential`.

```yaml
credentials:
  campus-v2c: { version: v2c, community: "..." }
```

| Key | |
| --- | --- |
| `version` | `v2c`. `v3` is not supported yet, and is an error. |
| `community` | The community string. A non-empty string. |

The names follow the [name rule](#names).

## targets

Each target is one device, and gets its own directory of records.

| Key | Default | |
| --- | --- | --- |
| `name` | (required) | The name of the device, used in the records and file names. Follows the [name rule](#names), and must be unique among the targets. |
| `host` | (required) | An IP address or a host name. |
| `family` | `auto` | `auto`, `ipv4`, or `ipv6`. |
| `snmp` | | The SNMP settings of the device. Required when the device has SNMP probes. |
| `probes` | (required) | What to measure. Must not be empty. |

`name` is not taken from `host`, so that the records keep one name when the address changes.

### host and family

- With an IP address, `family` must match it (an IPv4 address with `family: ipv6` is an error). An IPv6 address with a zone (`fe80::1%eth0`) is not accepted.
- With a host name, `family: auto` looks up A, and AAAA only when there is no A. `ipv4` and `ipv6` look up only A or only AAAA.
  - When A cannot be looked up for another reason (a timeout, for example), Detchi does not fall back to AAAA, so that a slow DNS does not move a device to IPv6.
- Host names are looked up again every `resolve_interval`. If a lookup fails, Detchi keeps measuring the last address. Failures and changes of the address are written to the records.
  - When a name has several addresses, Detchi keeps the one it uses as long as it is still in the answer.
  - A host name that cannot be looked up at startup does not stop Detchi; it is tried again after 10s, 20s, 40s, and so on, up to `resolve_interval`.
- Names are looked up the usual way of the host (`/etc/hosts` and DNS). TTLs are not followed.

### snmp

| Key | Default | |
| --- | --- | --- |
| `credential` | (required) | The name of an entry in `credentials`. |
| `port` | `161` | The UDP port of the agent. |

The credential is set per device, not per probe. `snmp` can be written on a device without SNMP probes.

## probes

Keys common to all probes:

| Key | Default | |
| --- | --- | --- |
| `name` | (required) | Follows the [name rule](#names), and must be unique within the target. |
| `protocol` | (required) | `icmp`, `tcp`, `udp`, or `snmp`. |
| `interval` | `defaults.interval` | How often to measure. |
| `timeout` | `defaults.timeout` (`defaults.snmp_timeout` for SNMP) | How long to wait for an answer. Must be shorter than `interval`. |

A key that does not belong to the protocol (`port` on an ICMP probe, for example) is an unknown key.

Measurements are spread over the interval by a phase taken from the names of the target and the probe, so that the probes do not all start at once. The phase is the same across restarts. After a start, the first measurement of a probe can take up to its `interval`.

### icmp

An ICMP Echo (ping). No other keys.

Detchi uses unprivileged ICMP sockets, so `net.ipv4.ping_group_range` must include the group of the user that runs it. The default of Docker is fine. `detchi run` checks this at startup, and does not start if it cannot open the sockets it needs.

### tcp

The time to connect. Detchi connects, and closes as soon as it is connected, sending nothing.

| Key | |
| --- | --- |
| `port` | (required) The port, 1 to 65535. |

- Some services log each connection. sshd, for example, writes a line like `Connection closed by ... [preauth]`: 1440 lines a day at `60s`. Mechanisms such as fail2ban, or the counts of failed logins on a device, may take notice.
- With a long `timeout` (over the 1 second of the first SYN retransmission of Linux), the RTT may include a retransmitted SYN.

### udp

One request that a server is sure to answer. Any UDP answer from the target counts as success; its contents are not checked.

| Key | Default | |
| --- | --- | --- |
| `service` | (required) | `dns`, `ntp`, or `quic`. |
| `port` | `53` / `123` / `443` | The port. The default comes from `service`. |

| `service` | The request |
| --- | --- |
| `dns` | A query for `. SOA`, without recursion (RD=0) and without EDNS. |
| `ntp` | An NTPv4 client request (mode 3). |
| `quic` | An Initial packet of a reserved version, which a server answers with Version Negotiation. |

With `service: ntp`, an `interval` under 8 seconds gives a warning. Public NTP servers take frequent queries for abuse, and rate-limit or drop them; do not query servers you do not run at short intervals.

### snmp

One SNMP get: one request, with all the OIDs as varbinds of one PDU.

| Key | |
| --- | --- |
| `oids` | (required) The OIDs, as numeric strings (`"1.3.6.1.2.1.1.3.0"`). Must not be empty. MIB names are not accepted. |

- The target must have `snmp`.
- Requests are not retried, so that losses show in the records.
- Values are recorded raw: counters are not turned into rates.
- Put `sysUpTime.0` (`1.3.6.1.2.1.1.3.0`) in the same request as the counters. It shows when the agent restarted, and gives the exact time between two samples. It wraps after about 497 days.
- Prefer the 64-bit counters (`ifHCInOctets` and so on). The 32-bit `ifInOctets` wraps in about 34 seconds at 1 Gbps.
- A request larger than the agent accepts is dropped by the agent without an answer, and is recorded as a `timeout`, not `tooBig`. If a probe with many OIDs always times out, split it.
- An agent that is not there, a closed port, and a wrong community all look the same: a `timeout`.

## Names

Names of targets, probes, and credentials match `^[a-z0-9][a-z0-9._-]{0,62}$`:

- lowercase letters, digits, `.`, `_`, and `-`, from 1 to 63 characters,
- not starting with `.`, `_`, or `-`.

Target names are used as directory and file names. Lowercase only, so that names that differ only in case do not collide when the records are downloaded to Windows or macOS. An IPv4 address or a host name can be a name; an IPv6 address cannot (`:` is not allowed in Windows file names).

## Durations

A positive integer with a unit: `ms`, `s`, `m`, or `h` (`500ms`, `60s`, `5m`, `1h`). A number without a unit is an error, so that milliseconds and seconds cannot be mixed up. `60s` and `1m` are the same.

## Reusing probes with anchors

Detchi has no templates of its own. Use YAML anchors (`&name` to name a node, `*name` to use it), and put the anchor under a top-level key that starts with `x-`:

```yaml
x-switch-probes: &switch
  - { name: ping, protocol: icmp }
  - { name: ssh,  protocol: tcp, port: 22 }

targets:
  - { name: sw1, host: 192.0.2.11, probes: *switch }
  - { name: sw2, host: 192.0.2.12, probes: *switch }
```

- Write an anchored list or mapping in block style, as above (the items on the lines after `&switch`). The YAML parser of Detchi puts an anchor on a flow collection (`&switch [...]` or `&switch {...}`) on its first item instead, so Detchi reports it as an error. An anchor on an item inside a flow collection (`[&a 1]`) is fine.
- Merge keys (`<<: *name`) are not supported; `<<` is an unknown key.
- An error in an anchored node is reported once for each use, at the position of the anchor.

## Changing the config

Restart Detchi after changing the config (restart the process or the container). Detchi does not reload the file; SIGHUP does not reload it either, but stops Detchi. Run `detchi check-config` before restarting: with an error in the file, Detchi does not start, and a container with `restart: unless-stopped` keeps restarting without measuring.

On a restart, the `stop` and `start` lines in the records show the gap. Each `start` line holds the config fingerprint of its target (`config_hash`), so changes of the config can be found in the records.

- The fingerprint covers only the definition of that target, with the left-out values filled in by their defaults: `name`, `host`, `family`, `snmp` (`port`, and the `version` of the credential), and `probes`. It does not cover credentials, the name of the credential, the looked-up address, or the top-level keys.
- Reordering the probes, or writing `60s` as `1m`, does not change it. Reordering the `oids` does.
- A new version of Detchi can change the fingerprint without a change of the config, when it changes defaults or keys. The `version` in the `start` line tells which.
- To see what changed, compare the output of `detchi check-config --fingerprints` for the two configs. Each line starts with the target name, so `diff` and `grep` work on it.

## Credentials and safety

The file holds the SNMP communities in plain text.

- Detchi never writes them to the records, error messages, or logs.
- Showing the file to someone shows them the credentials too. Use `detchi check-config --fingerprints` to share the definitions of targets; its output holds no credentials.
- Keep the file readable only by the user that runs Detchi.
