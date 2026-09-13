# beam sidecar image: runs OtpRailsBeam.Queue (ROLE=queue) or
# OtpRailsBeam.Cable (ROLE=cable) against the app's Postgres databases.
# otp_rails_beam is consumed straight from the shishi-odoshi/beam git repo.
FROM elixir:1.18

RUN apt-get update && \
    apt-get install -y --no-install-recommends git procps && \
    rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod

WORKDIR /runner
# builds.hex.pm timeouts are an observed transient CI failure mode (60s
# request timeout killed a whole integration run); retry the
# network-dependent bootstrap steps instead of failing the stack on a blip.
RUN for i in 1 2 3 4 5; do \
      mix local.hex --force && mix local.rebar --force && break; \
      [ "$i" = 5 ] && exit 1; \
      echo "hex/rebar bootstrap failed (attempt $i) — retrying in 15s"; sleep 15; \
    done

COPY runner/mix.exs ./
RUN for i in 1 2 3 4 5; do \
      mix deps.get && break; \
      [ "$i" = 5 ] && exit 1; \
      echo "mix deps.get failed (attempt $i) — retrying in 15s"; sleep 15; \
    done && \
    mix deps.compile

COPY runner/lib lib
RUN mix compile

COPY start.sh /start.sh
RUN chmod +x /start.sh

CMD ["/start.sh"]
