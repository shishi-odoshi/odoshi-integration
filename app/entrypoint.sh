#!/usr/bin/env bash
# Generate a supervised Rails app FRESH from odoshi-template's template.rb,
# patch it for the integration stack (Postgres multi-DB, odoshi-resilience,
# queue routing, integration endpoints), prepare the databases, and run it
# under bin/supervise (odoshi).
#
# The supervisor is intentionally NOT PID 1: after it exits, its status is
# written to /tmp/supervise.exit and the container stays alive so the harness
# can audit for orphaned processes and the unlinked socket (phase 7).
set -euxo pipefail

export RAILS_ENV=production
: "${SECRET_KEY_BASE:?SECRET_KEY_BASE must be set}"
export PORT="${PORT:-3000}"

APP_DIR=/work/app
TEMPLATE_URL="${TEMPLATE_URL:-https://raw.githubusercontent.com/shishi-odoshi/odoshi-template/main/template.rb}"

echo "==> fetching application template: $TEMPLATE_URL"
curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors "$TEMPLATE_URL" -o /tmp/template.rb

echo "==> rails new (fresh, from template, postgres)"
rails new "$APP_DIR" \
  --database=postgresql \
  --skip-git --skip-docker --skip-kamal --skip-ci \
  -m /tmp/template.rb

cd "$APP_DIR"

echo "==> applying integration patches"
/harness/patches/apply.sh "$APP_DIR"

echo "==> bundle install (odoshi-resilience via git source)"
bundle install

echo "==> db:prepare (primary + queue + cable + cache)"
bin/rails db:prepare

echo "==> starting bin/supervise"
bin/supervise &
SUP=$!
echo "$SUP" > /tmp/supervise.pid

set +e
wait "$SUP"
CODE=$?
set -e
echo "$CODE" > /tmp/supervise.exit
echo "==> supervisor exited with status $CODE"

# Keep the container alive for the post-shutdown audit.
sleep infinity
