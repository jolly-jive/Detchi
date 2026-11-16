# Detchi in a container (docs/operation.md, "Running in a container").
#
#   docker build -t detchi .
#
# The escript does not include ERTS, so the run stage is an Erlang image,
# not plain Alpine. Both stages are multi-arch (amd64, arm64).
#
# The escript is BEAM code only (no NIFs, in Detchi or its deps), so it is
# the same on every architecture: the build stage runs once, natively on
# the build host, and only the run stage is built per target platform.
#
#   docker buildx build --platform linux/amd64,linux/arm64 -t detchi .

FROM --platform=$BUILDPLATFORM elixir:1.19-otp-28-alpine AS build
WORKDIR /src
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
RUN mix escript.build

FROM erlang:28-alpine
# tzdata: TZ decides the date of the record files and the offset of ts.
RUN apk add --no-cache tzdata \
 && addgroup -S -g 1000 detchi \
 && adduser -S -D -H -h /var/lib/detchi -s /sbin/nologin -u 1000 -G detchi detchi \
 && install -d -o detchi -g detchi -m 0755 /var/lib/detchi \
 && install -d -m 0755 /etc/detchi
COPY --from=build /src/detchi /usr/local/bin/detchi
# No root, no capabilities: ICMP uses unprivileged sockets, which the
# default net.ipv4.ping_group_range of Docker allows for every group.
USER detchi
WORKDIR /var/lib/detchi
ENTRYPOINT ["detchi"]
CMD ["run"]
