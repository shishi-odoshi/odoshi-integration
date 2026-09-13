# beam sidecar image: runs OtpRailsBeam.Queue (ROLE=queue) or
# OtpRailsBeam.Cable (ROLE=cable) against the app's Postgres databases.
# otp_rails_beam is consumed straight from the shishi-odoshi/beam git repo.
FROM elixir:1.18

RUN apt-get update && \
    apt-get install -y --no-install-recommends git procps && \
    rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod

WORKDIR /runner
RUN mix local.hex --force && mix local.rebar --force

COPY runner/mix.exs ./
RUN mix deps.get && mix deps.compile

COPY runner/lib lib
RUN mix compile

COPY start.sh /start.sh
RUN chmod +x /start.sh

CMD ["/start.sh"]
