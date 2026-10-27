# Detchi

English | [日本語](README.ja.md)

A service that only collects and records network metrics: the RTT over ICMP / TCP / UDP, and values over SNMP. It runs on Linux, keeps measuring network devices, and writes what it measures to files as JSON Lines.

Detchi does not alert, chart, or compute statistics. Download the records and do that elsewhere.

Written in Elixir/OTP. Made to be built into [Koitohan](#koitohan) (a small management server for network devices on a Raspberry Pi), but it does not depend on Koitohan.

*Detchi is in development and has no release yet.*

## The name

"でっち (丁稚)", the apprentice of a merchant house in old Osaka. Koitohan is named after the youngest daughter of such a house, so the two live under the same roof. An apprentice's work was hard, but it was also the start of a career: clerk, head clerk, and in the end a shop of one's own. For now Detchi only writes down RTTs and SNMP values; it may learn gNMI and NETCONF as it grows.

## Features (so far)

- RTT over ICMP Echo, TCP connect, and UDP (DNS, NTP, QUIC).
- SNMP v2c get. v3 is not supported yet.
- One YAML config file, checked strictly: unknown keys, duplicate keys, and wrong types stop Detchi at startup, with the line and column.
- Credentials never appear in the records, error messages, or logs.
- Measurements of a probe start at a fixed phase of its interval, taken from the names, so they are spread out and stay the same across restarts.
- Host names are looked up again at an interval; a failed lookup keeps the last address.
- One record file per target per day (the local date, by `TZ`), compressed with gzip or zstd once the day is over, and deleted after `retention_days`.
- `start` and `stop` lines, a config fingerprint per target, and lines for steps of the wall clock, so gaps and changes can be read from the records.

## Requirements

- Linux.
- Erlang/OTP 28 or later (zstd needs OTP 28). The escript does not include ERTS.
- Elixir 1.19 or later, to build.
- For ICMP, `net.ipv4.ping_group_range` must include the group of the user (Detchi uses unprivileged ICMP sockets). The default of Docker is fine.

## Build and run

```sh
mix deps.get
MIX_ENV=prod mix escript.build   # writes ./detchi
```

```sh
./detchi check-config            # check the config file
./detchi run                     # run as a service
```

The config file is `$DETCHI_CONFIG`, or `/etc/detchi/detchi.yml`. A short example:

```yaml
data_dir: /var/lib/detchi
compression: gzip

credentials:
  campus-v2c: { version: v2c, community: "..." }

targets:
  - name: core1
    host: 192.0.2.1
    snmp:
      credential: campus-v2c
    probes:
      - { name: ping, protocol: icmp }
      - { name: ssh,  protocol: tcp, port: 22 }
      - { name: sysuptime, protocol: snmp, interval: 300s, oids: ["1.3.6.1.2.1.1.3.0"] }
```

To change the config, restart Detchi. SIGHUP does not reload it.

## Documents

- [Basic design](docs/basic-design.md) (Japanese only): the background, the decisions, and what is still open.

## Koitohan

Koitohan is a small management server for network devices, by the same author, not public yet. Detchi is a general service; what is specific to Koitohan is added on the side of Koitohan.

## License

Copyright 2026 Cayenne Ryo

Licensed under the [Apache License 2.0](LICENSE). See also [NOTICE](NOTICE).

## Ice cream

If Detchi saves you some trouble, buy me an ice cream. 🍦

*This is a request, not a license term. Detchi is under Apache-2.0, with no extra conditions.*
