# Operation

English | [日本語](operation.ja.md)

How to build, run, stop, and watch Detchi.

## Contents

- [Building](#building)
- [Commands](#commands)
- [Starting](#starting)
- [Stopping](#stopping)
- [Changing the config, and upgrading](#changing-the-config-and-upgrading)
- [Logs](#logs)
- [Checking that Detchi is working](#checking-that-detchi-is-working)
- [What Detchi writes](#what-detchi-writes)
- [Running in a container](#running-in-a-container)
- [Crash dumps](#crash-dumps)

## Building

Detchi is distributed as source tags, and built into an escript: one file, `detchi`.

```sh
git clone https://github.com/jolly-jive/detchi.git
cd detchi
git checkout <tag>
mix deps.get
MIX_ENV=prod mix escript.build   # writes ./detchi
```

- Building needs Elixir 1.19 or later and Erlang/OTP 28 or later.
- Running needs Erlang/OTP 28 or later. The escript does not include ERTS, and its first line is `#! /usr/bin/env escript`, so `escript` must be on `PATH`.
- Detchi runs on Linux only.

## Commands

| Command | |
| --- | --- |
| `detchi run` | Runs as a service, recording measurements, until it is stopped. |
| `detchi check-config` | Checks the config file and exits (see [Configuration](configuration.md#checking-the-file)). |
| `detchi check-config --fingerprints` | Also prints the config fingerprint of each target. |
| `detchi status` | Prints when each target was last written, and exits (see [Checking that Detchi is working](#checking-that-detchi-is-working)). |
| `detchi status -q` | Prints only the targets that are not written to. |
| `detchi --version` | Prints the version. |
| `detchi --help` | Prints the usage. |

The config file is `$DETCHI_CONFIG`, or `/etc/detchi/detchi.yml`.

| Exit status | |
| --- | --- |
| 0 | Success. For `detchi run`, it was stopped by SIGTERM or SIGHUP. |
| 1 | An error: the config has errors, or `detchi run` could not start. For `detchi status`, also a target that is not written to. |
| 2 | Wrong usage (an unknown command or option). |

## Starting

`detchi run`:

1. Reads and checks the config file. With errors, prints them to stderr and exits with 1. Warnings go to the log.
2. Checks that it can open the ICMP sockets that the ICMP probes need. If not, prints why to stderr and exits with 1: `net.ipv4.ping_group_range` must include the group of the user.
3. Writes the files of the SNMP manager of Erlang into `<temporary directory>/detchi-<OS pid>/`, and removes them when it stops. The temporary directory is the first writable one of `TMPDIR`, `TEMP`, `TMP`, `/tmp`, and, as a last resort, the current directory. If none is writable, Detchi exits with 1.
4. Writes a `start` line to the file of each target, and starts measuring.

The first measurement of a probe comes within its `interval` after the start, at the phase taken from its names (see [Configuration](configuration.md#probes)).

A host name that cannot be looked up at startup does not stop Detchi (see [Configuration](configuration.md#host-and-family)).

## Stopping

Stop Detchi with **SIGTERM** (`kill`, `docker stop`, `systemctl stop`) or SIGHUP. It then:

- stops waiting for the answers of requests in flight, without writing their lines, so that it stops within the 10 seconds of `docker stop`,
- writes a `stop` line to the file of each target, with the count of the requests it stopped waiting for (`abandoned`),
- closes the files, and exits with 0.

SIGHUP does not reload the config; it stops Detchi, as SIGTERM does.

SIGINT (Ctrl-C in a terminal) stops Detchi at once, **without a `stop` line**, with exit status 130. The records then look as if Detchi had crashed. The Erlang VM does not let Detchi handle SIGINT.

## Changing the config, and upgrading

Detchi reads the config only at startup. To change it:

1. Edit the file.
2. Run `detchi check-config`. With an error, Detchi would not start.
3. Restart Detchi.

The restart shows in the records as `stop` and `start` lines. With an interval of 60 seconds, a restart loses about one measurement.

To upgrade, build the new tag and restart in the same way. Check the config with the new `detchi check-config` first: a new version can add checks. A new version can also change the config fingerprints without a change of the config (see [Configuration](configuration.md#changing-the-config)).

## Logs

Detchi logs to stdout, one line per message with the time and the level:

```
00:05:48.543 [error] core1: dropping lines: cannot write /var/lib/detchi/core1/core1-2026-10-28.jsonl (eacces)
00:05:53.921 [notice] SIGTERM received - shutting down
```

What is logged:

- warnings of the config, at startup,
- lines that cannot be written (`dropping lines`), and when they can be written again (`writing again`),
- record files that cannot be compressed or deleted (they are tried again later),
- the details of `internal` errors of probes.

Detchi keeps running when it cannot write, so that it can go on when the disk has room again. Watch the log, or the records (below), to notice it.

Credentials never appear in the log.

## Checking that Detchi is working

Detchi writes a line for every measurement, failures included, so a target whose file is written to recently is being measured.

`detchi status` checks this for each target in the config:

```
$ detchi status
ok     core1  last 2026-10-24T01:23:45+09:00  age 12s    limit 121s
stale  sw1    last 2026-10-24T01:05:02+09:00  age 1135s  limit 121s
stale  sw2    never written                              limit 121s
```

- `last` is when the files of the target were last modified, and `age` how long ago that was. Just after midnight, the file of the previous day can be newer than the one of today, so the files of the two latest dates are looked at.
- A target is `stale` when `age` is longer than `limit`, or when it has never been written. `limit` is twice the shortest `interval` of its probes plus the longest `timeout`, and at least 30s. With the defaults (`interval` 60s, `timeout` 1s), it is 121s.
- `-q` prints only the `stale` lines, and nothing when every target is `ok`.
- It exits with 0 when every target is `ok`, and with 1 when a target is `stale`, or when it cannot tell: the config has errors, or a directory in `data_dir` cannot be read. Those errors, and the warnings of the config, go to stderr. A missing `data_dir` is not an error: every target is `never written`.
- The exit status fits the `HEALTHCHECK` of a container, which takes 0 as healthy and 1 as unhealthy.

`detchi status` reads the config file and `data_dir`, and writes nothing. It does not talk to the running Detchi: a Detchi that has stopped and one that is stuck look the same, not written to.

Things to know:

- It reads the config file as it is now. A target added without restarting Detchi is `never written`.
- When the wall clock jumps forward (when chrony sets the clock of a machine without an RTC, for example), a target can look `stale` until its next line is written. A file modified in the future (the clock jumped back) counts as written now.

## What Detchi writes

| Where | What |
| --- | --- |
| `data_dir` | The records. Directories are 0755 and files 0644 whatever the umask is, so that other users can read and download them. |
| The temporary directory | The files of the SNMP manager, a few KB, removed at a stop by SIGTERM or SIGHUP. A stop by another signal (SIGINT, for example) leaves the directory behind. |
| stdout | The log. |
| stderr | Errors that stop `detchi run` at startup, the output of `detchi check-config` when there are errors, and the errors and warnings of `detchi status`. |

Detchi writes nothing else: no PID file, and no crash dump unless asked for (see [Crash dumps](#crash-dumps)).

Detchi needs no privileges: no root, no capabilities, and no setuid. The config file must be readable by the user that runs it, and `data_dir` writable.

## Running in a container

Detchi works as a container with these settings:

- **An image with Erlang/OTP 28 or later**, such as `erlang:28-alpine`. Build the escript in an earlier stage of a multi-stage build, and copy it in.
- **`TZ`**, for the dates of the files and the offsets of `ts`. Alpine needs the `tzdata` package.
- **A volume at `data_dir`** for the records.
- **`read_only: true`** works, with a tmpfs at `/tmp` (or `TMPDIR`) for the files of the SNMP manager.
- **`security_opt: no-new-privileges:true`** works: Detchi needs no setuid and no file capabilities.
- **A user other than root.** The default `net.ipv4.ping_group_range` of Docker allows ICMP sockets for every group.
- **`restart: unless-stopped`** brings Detchi back after a crash. Run `detchi check-config` before a restart: with an error in the config, the container keeps restarting without measuring.
- `docker stop` sends SIGTERM, and Detchi stops within its 10 seconds.
- The log is on stdout: `docker logs` or `docker compose logs`.
- Detchi only sends requests out. It opens no port for others to connect to; the SNMP manager receives the answers on a UDP port chosen by the OS.

## Crash dumps

When the Erlang VM crashes, it can write a crash dump (`erl_crash.dump`). Detchi turns this off by default: a dump holds the memory of the processes, and so the SNMP communities of the config.

To get a dump while investigating a crash, set both variables when starting Detchi:

```sh
ERL_CRASH_DUMP=/var/tmp/detchi.dump ERL_CRASH_DUMP_SECONDS=60 detchi run
```

- `ERL_CRASH_DUMP` is where to write it. `ERL_CRASH_DUMP_SECONDS` is the time allowed to write it; `0` (the default of Detchi) writes none.
- A dump is several MB. Put it somewhere writable and lasting: not a tmpfs, which is lost when the container stops.
- **The dump holds the credentials.** Delete it when done, and do not share it as it is.

Without a dump, the reason for a stop is still in the log, just before it stops (`Kernel pid terminated ...` and so on).
