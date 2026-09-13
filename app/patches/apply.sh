#!/usr/bin/env bash
# Post-generation patches that turn the template's generated app into the
# integration harness shape. Everything here is the "realistic production
# reconfiguration" layer — the generated app itself is untouched template
# output. Each patch states which seam it serves.
set -euxo pipefail

APP_DIR="${1:?usage: apply.sh APP_DIR}"
PATCHES="$(cd "$(dirname "$0")" && pwd)"
cd "$APP_DIR"

# --- 1. Postgres, 4 production databases (primary/queue/cable/cache) --------
# The realistic Rails 8 production shape; beam attaches to queue + cable.
cp "$PATCHES/database.yml" config/database.yml

# --- 2. Queue routing: Ruby workers keep "default", beam owns "elixir" ------
# Solid Queue's generated queue.yml has workers on "*", which would let the
# Ruby worker claim beam's designated queue. The dispatcher still dispatches
# every queue (scheduled jobs flow to beam once ready).
cp "$PATCHES/queue.yml" config/queue.yml

# --- 3. otp-rails-resilience (unpublished — git source) ---------------------
cat >> Gemfile <<'RUBY'

# Integration harness: crash-only conventions, Rails.supervisor.restart!,
# telemetry bridge, boot:check (unpublished; consumed from git).
gem "otp-rails-resilience", github: "shishi-odoshi/otp-rails-resilience",
                            require: "otp_rails/resilience"
RUBY

# --- 4. Integration surface: marker model/jobs + HTTP endpoints -------------
# IntegrationMarkerJob/SlowMarkerJob write job_markers rows tagged with which
# runtime executed them ("ruby" here; the beam handler writes "beam"), so
# exactly-once and routing assertions are plain SQL.
mkdir -p app/models app/jobs app/controllers db/migrate
cp "$PATCHES/job_marker.rb"             app/models/job_marker.rb
cp "$PATCHES/integration_marker_job.rb" app/jobs/integration_marker_job.rb
cp "$PATCHES/slow_marker_job.rb"        app/jobs/slow_marker_job.rb
cp "$PATCHES/integration_controller.rb" app/controllers/integration_controller.rb
cp "$PATCHES/create_job_markers.rb"     db/migrate/20260101000000_create_job_markers.rb

ruby -e '
  path = "config/routes.rb"
  src = File.read(path)
  inject = <<-ROUTES
  # Integration harness endpoints (exercised over HTTP so enqueue/broadcast/
  # restart! all originate inside supervised app processes).
  get "/integration/enqueue",       to: "integration#enqueue"
  get "/integration/broadcast",     to: "integration#broadcast"
  get "/integration/signed_stream", to: "integration#signed_stream"
  get "/integration/restart_jobs",  to: "integration#restart_jobs"
  ROUTES
  src.sub!(/Rails\.application\.routes\.draw do\n/) { |m| m + inject } or abort "routes.rb: draw block not found"
  File.write(path, src)
'

# --- 5. Production environment tweaks ---------------------------------------
# a) No TLS inside the compose network (only /up is excluded by default).
# b) Fast Solid Queue process liveness so the ProcessPrunedError phase
#    (otp-rails#41 semantics) fits CI: heartbeat 3s, prunable after 15s.
#    Applies to Ruby and (via config) beam workers alike.
ruby -e '
  path = "config/environments/production.rb"
  src = File.read(path)
  src.gsub!("config.assume_ssl = true", "config.assume_ssl = false")
  src.gsub!("config.force_ssl = true", "config.force_ssl = false")
  extra = <<-RUBY

  # Integration harness: fast process liveness so dead-worker pruning
  # (ProcessPrunedError) is observable within CI timescales.
  config.solid_queue.process_heartbeat_interval = 3.seconds
  config.solid_queue.process_alive_threshold = 15.seconds
  RUBY
  src.sub!(/^end\s*\Z/) { extra + "end\n" } or abort "production.rb: trailing end not found"
  File.write(path, src)
'

echo "patches applied"
