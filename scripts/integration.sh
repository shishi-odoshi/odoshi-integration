#!/usr/bin/env bash
# Full-stack integration test for the shishi-odoshi otp-rails project.
#
# Stands up postgres + a freshly template-generated Rails app under
# bin/supervise (otp-rails) + the beam Solid Queue worker and cable server,
# then runs the phased test program:
#
#   1 steady-state        both queues drain exactly-once; ws broadcast round-trip
#   2 chaos-web           kill -9 puma; /up back < 10s; cable still delivers
#   3 chaos-ruby-jobs     kill -9 bin/jobs; default continues; elixir unaffected
#   4 chaos-beam-queue    kill -9 beam worker mid-burst; claimed jobs FAIL with
#                         ProcessPrunedError after prune (otp-rails#41 semantics);
#                         unclaimed drain on return; default unaffected
#   5 chaos-cable         kill beam cable; ws client reconnects; no replay
#   6 resilience-in-situ  bin/rails boot:check; Rails.supervisor.restart!(:jobs)
#                         from app code restarts the jobs child (§9 control path)
#   7 clean-teardown      TERM the supervisor -> exit 0, no orphans, socket gone
#
# Ends with a scoreboard. Exit 0 iff every phase passed.
set -uo pipefail

cd "$(dirname "$0")/.."
mkdir -p logs

COMPOSE="docker compose"
OVERALL=0
SCOREBOARD=()

WS_URL="ws://beam-cable:28080/cable"
APP_BASE="http://127.0.0.1:3000"

# ---------------------------------------------------------------- helpers ---
appx()     { $COMPOSE exec -T app "$@"; }
appw()     { $COMPOSE exec -T -w /work/app app "$@"; }
curl_app() { appx curl -fsS "$APP_BASE$1"; }
psqlq()    { $COMPOSE exec -T postgres psql -U postgres -d "$1" -tAc "$2" | tr -d '[:space:]'; }

q_queue()   { psqlq app_production_queue "$1"; }
q_primary() { psqlq app_production "$1"; }

sql_eq() { [ "$(psqlq "$1" "$2")" = "$3" ]; }

unfinished() { q_queue "SELECT count(*) FROM solid_queue_jobs WHERE arguments LIKE '%${1}-%' AND finished_at IS NULL"; }
finished()   { q_queue "SELECT count(*) FROM solid_queue_jobs WHERE arguments LIKE '%${1}-%' AND finished_at IS NOT NULL"; }
claimed()    { q_queue "SELECT count(*) FROM solid_queue_claimed_executions ce JOIN solid_queue_jobs j ON j.id = ce.job_id WHERE j.arguments LIKE '%${1}-%'"; }
failed()     { q_queue "SELECT count(*) FROM solid_queue_failed_executions f JOIN solid_queue_jobs j ON j.id = f.job_id WHERE j.arguments LIKE '%${1}-%'"; }
pruned_failed() { q_queue "SELECT count(*) FROM solid_queue_failed_executions f JOIN solid_queue_jobs j ON j.id = f.job_id WHERE j.arguments LIKE '%${1}-%' AND f.error LIKE '%ProcessPrunedError%'"; }
markers()         { q_primary "SELECT count(*) FROM job_markers WHERE source = '${1}' AND marker LIKE '${2}-%'"; }
markers_distinct(){ q_primary "SELECT count(DISTINCT marker) FROM job_markers WHERE source = '${1}' AND marker LIKE '${2}-%'"; }
markers_any()     { q_primary "SELECT count(*) FROM job_markers WHERE marker LIKE '${1}-%'"; }

wait_until() { # DESC TIMEOUT_SECONDS COMMAND...
  local desc=$1 timeout=$2 start=$SECONDS
  shift 2
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS - start > timeout )); then
      echo "TIMEOUT after ${timeout}s waiting for: $desc" >&2
      return 1
    fi
    sleep 1
  done
  echo "ok (${desc}) after $(( SECONDS - start ))s"
}

assert_eq() { # ACTUAL EXPECTED DESC
  if [ "$1" = "$2" ]; then
    echo "assert ok: $3 ($1)"
  else
    echo "ASSERT FAILED: $3 — expected $2, got $1" >&2
    return 1
  fi
}

enqueue() { # QUEUE COUNT PREFIX [slow]
  local job="${4:-marker}"
  curl_app "/integration/enqueue?queue=$1&count=$2&prefix=$3&job=$job" | grep -q "\"enqueued\":$2"
}

assert_drained_exactly_once() { # PREFIX COUNT SOURCE TIMEOUT
  local prefix=$1 count=$2 source=$3 timeout=$4
  wait_until "$prefix drained ($count jobs finished)" "$timeout" sql_eq app_production_queue \
    "SELECT count(*) FROM solid_queue_jobs WHERE arguments LIKE '%${prefix}-%' AND finished_at IS NOT NULL" "$count"
  assert_eq "$(failed "$prefix")" 0 "$prefix: no failed executions"
  assert_eq "$(markers "$source" "$prefix")" "$count" "$prefix: $count marker rows from $source"
  assert_eq "$(markers_distinct "$source" "$prefix")" "$count" "$prefix: markers distinct (exactly-once)"
  assert_eq "$(markers_any "$prefix")" "$count" "$prefix: no rows from the other runtime"
}

app_health() { docker inspect --format '{{.State.Health.Status}}' "$($COMPOSE ps -q app)" 2>/dev/null; }

ws_roundtrip() { # MESSAGE
  appx ruby /harness/ws_client.rb roundtrip "$WS_URL" "$APP_BASE" "$1" | grep -q "ROUNDTRIP_OK $1"
}

kill_beam_node() { # SERVICE
  $COMPOSE exec -T "$1" pkill -9 beam.smp
}

jobs_pids() { { appx pgrep -f 'solid-queu[e]|bin/job[s]' 2>/dev/null || true; } | sort | tr '\n' ' '; }

# ----------------------------------------------------------------- phases ---
phase_setup() {
  $COMPOSE down -v --remove-orphans >/dev/null 2>&1 || true
  $COMPOSE build --pull
  $COMPOSE up -d postgres app

  local start=$SECONDS
  while :; do
    local state health
    state="$(docker inspect --format '{{.State.Status}}' "$($COMPOSE ps -aq app)" 2>/dev/null || echo unknown)"
    health="$(app_health || echo unknown)"
    [ "$health" = "healthy" ] && break
    if [ "$state" = "exited" ]; then
      echo "app container exited during setup" >&2
      $COMPOSE logs --no-color app | tail -50 >&2
      return 1
    fi
    if (( SECONDS - start > 900 )); then
      echo "TIMEOUT: app never became healthy" >&2
      $COMPOSE logs --no-color app | tail -50 >&2
      return 1
    fi
    sleep 5
  done
  echo "app healthy after $(( SECONDS - start ))s (fresh app generated, supervised, /up answering)"

  $COMPOSE up -d beam-queue beam-cable
  wait_until "beam queue worker registered in solid_queue_processes" 180 sql_eq app_production_queue \
    "SELECT count(*) > 0 FROM solid_queue_processes WHERE kind = 'Worker' AND metadata LIKE '%beam%'" "t" \
    || { beam_diagnostics; return 1; }
  wait_until "beam cable server listening" 180 \
    appx ruby -e 'require "socket"; TCPSocket.new("beam-cable", 28080).close' \
    || { beam_diagnostics; return 1; }
}

beam_diagnostics() { # dumped when beam never comes up (container state + logs)
  {
    echo "---- docker compose ps -a ----"
    $COMPOSE ps -a || true
    echo "---- beam-queue logs (tail) ----"
    $COMPOSE logs --no-color --tail 60 beam-queue || true
    echo "---- beam-cable logs (tail) ----"
    $COMPOSE logs --no-color --tail 60 beam-cable || true
  } >&2
}

phase_1_steady_state() {
  curl_app /up >/dev/null
  echo "assert ok: /up 200"

  enqueue default 20 p1d
  enqueue elixir 20 p1e
  assert_drained_exactly_once p1d 20 ruby 120
  assert_drained_exactly_once p1e 20 beam 120

  ws_roundtrip "p1-cable-msg"
  echo "assert ok: Rails broadcast -> Solid Cable -> beam -> ws client"
}

phase_2_chaos_web() {
  appw bin/rails "chaos:kill[web]"      # asserts /up back < 10s or aborts
  curl_app /up >/dev/null
  ws_roundtrip "p2-after-web-recovery"
  echo "assert ok: cable delivery works after web recovery"
}

phase_3_chaos_ruby_jobs() {
  enqueue elixir 8 p3e slow             # keeps beam busy across the chaos window
  appw bin/rails "chaos:kill[jobs]"     # asserts jobs child respawned < 10s or aborts
  enqueue default 20 p3d
  assert_drained_exactly_once p3d 20 ruby 120
  assert_drained_exactly_once p3e 8 beam 120
}

phase_4_chaos_beam_queue() {
  enqueue default 10 p4d
  enqueue elixir 12 p4e slow

  wait_until "beam claimed p4e jobs (mid-burst)" 60 sql_eq app_production_queue \
    "SELECT count(*) > 0 FROM solid_queue_claimed_executions ce JOIN solid_queue_jobs j ON j.id = ce.job_id WHERE j.arguments LIKE '%p4e-%'" "t"
  kill_beam_node beam-queue
  local killed_at=$SECONDS

  local c; c="$(claimed p4e)"
  echo "claimed at kill: $c"
  [ "$c" -ge 1 ] || { echo "ASSERT FAILED: expected >=1 claimed execution at kill" >&2; return 1; }

  # The respawned worker registers fresh and drains everything still ready.
  wait_until "unclaimed p4e jobs drained by respawned beam worker" 120 sql_eq app_production_queue \
    "SELECT count(*) FROM solid_queue_jobs WHERE arguments LIKE '%p4e-%' AND finished_at IS NOT NULL" "$(( 12 - c ))"

  # Solid Queue semantics (otp-rails#41): claims of a pruned process are
  # FAILED with ProcessPrunedError, not released. Assert it, don't fight it.
  local since_kill=$(( SECONDS - killed_at ))
  (( since_kill < 20 )) && sleep $(( 20 - since_kill ))   # > process_alive_threshold (15s)
  appw bin/rails runner "SolidQueue::Process.prune" >/dev/null
  wait_until "orphaned claims failed with ProcessPrunedError" 30 sql_eq app_production_queue \
    "SELECT count(*) FROM solid_queue_failed_executions f JOIN solid_queue_jobs j ON j.id = f.job_id WHERE j.arguments LIKE '%p4e-%' AND f.error LIKE '%ProcessPrunedError%'" "$c"
  assert_eq "$(claimed p4e)" 0 "p4e: no dangling claimed executions"
  assert_eq "$(finished p4e)" "$(( 12 - c ))" "p4e: all unclaimed jobs finished"

  assert_drained_exactly_once p4d 10 ruby 120   # default side unaffected throughout
}

phase_5_chaos_cable() {
  local log=logs/ws_chaoscable.log
  : > "$log"
  appx ruby /harness/ws_client.rb chaoscable "$WS_URL" "$APP_BASE" p5-pre-msg p5-post-msg > "$log" 2>&1 &
  local ws_pid=$!

  if ! wait_until "ws client subscribed + pre-kill broadcast delivered" 60 grep -q READY_FOR_KILL "$log"; then
    cat "$log" >&2; kill "$ws_pid" 2>/dev/null; return 1
  fi
  kill_beam_node beam-cable

  if wait "$ws_pid" && grep -q CHAOS_CABLE_OK "$log"; then
    cat "$log"
  else
    cat "$log" >&2
    return 1
  fi
}

phase_6_resilience() {
  appw bin/rails boot:check
  echo "assert ok: boot:check passed on the generated app"

  local before after
  before="$(jobs_pids)"
  [ -n "$before" ] || { echo "ASSERT FAILED: no jobs child running before restart!" >&2; return 1; }
  echo "jobs pids before: $before"

  curl_app /integration/restart_jobs | grep -q '"supervised":true,"restarted":true'
  echo "assert ok: Rails.supervisor.restart!(:jobs) returned true from app code"

  restart_done() {
    local now overlap p
    now="$(jobs_pids)"
    [ -n "$now" ] || return 1
    for p in $now; do case " $before " in *" $p "*) return 1;; esac; done
  }
  wait_until "jobs child replaced (fresh pids)" 120 restart_done
  after="$(jobs_pids)"
  echo "jobs pids after:  $after"

  # Telemetry evidence (informational): the supervisor logs drain/spawn.
  $COMPOSE logs --no-color app 2>/dev/null | grep -E 'child\.(drain|spawn)|drain.*jobs|spawn.*jobs' | tail -5 || true

  curl_app /up >/dev/null
  echo "assert ok: web untouched by jobs restart"
}

phase_7_clean_teardown() {
  appx bash -c 'kill -TERM "$(cat /tmp/supervise.pid)"'
  wait_until "supervisor exited" 120 appx test -f /tmp/supervise.exit
  assert_eq "$(appx cat /tmp/supervise.exit | tr -d '[:space:]')" 0 "supervisor exit status 0 on TERM"

  local orphans
  orphans="$(appx ps -eo pid,args | grep -E 'pum[a]|solid-queu[e]|bin/job[s]|rails serve[r]' || true)"
  if [ -n "$orphans" ]; then
    echo "ASSERT FAILED: orphaned processes after supervisor exit:" >&2
    echo "$orphans" >&2
    return 1
  fi
  echo "assert ok: no orphaned app processes"

  appx bash -c 'test ! -e /work/app/tmp/otp-rails.sock'
  echo "assert ok: supervision socket unlinked"
}

run_phase() { # NAME FUNCTION
  local name=$1 fn=$2 result start dur status
  start=$(date +%s)
  echo
  echo "===================================================================="
  echo "  PHASE: $name"
  echo "===================================================================="
  # The subshell must NOT be an if-condition: bash suppresses errexit in any
  # tested context — even when `set -e` is re-enabled inside — which once let
  # a failed `compose build` slide through setup and mask the real error.
  ( set -eu; "$fn" )
  status=$?
  if [ "$status" -eq 0 ]; then result=PASS; else result=FAIL; OVERALL=1; fi
  dur=$(( $(date +%s) - start ))
  SCOREBOARD+=("$(printf '%-22s %-4s %5ss' "$name" "$result" "$dur")")
  echo "--- $name: $result (${dur}s)"
}

# -------------------------------------------------------------------- run ---
run_phase setup              phase_setup
if [ "$OVERALL" -ne 0 ]; then
  echo "setup failed — skipping test phases" >&2
  SCOREBOARD+=("$(printf '%-22s %-4s %5s' phases-1-7 SKIP -)")
else
  run_phase 1-steady-state     phase_1_steady_state
  run_phase 2-chaos-web        phase_2_chaos_web
  run_phase 3-chaos-ruby-jobs  phase_3_chaos_ruby_jobs
  run_phase 4-chaos-beam-queue phase_4_chaos_beam_queue
  run_phase 5-chaos-cable      phase_5_chaos_cable
  run_phase 6-resilience       phase_6_resilience
  run_phase 7-clean-teardown   phase_7_clean_teardown
fi

# Capture everything diagnosable into the artifact, including container
# STATE (a service whose image never built produces no log lines at all —
# the ps snapshot is what shows it was never created).
$COMPOSE logs --no-color > logs/compose.log 2>&1 || true
$COMPOSE ps -a > logs/compose-ps.txt 2>&1 || true
for svc in postgres app beam-queue beam-cable; do
  $COMPOSE logs --no-color "$svc" > "logs/$svc.log" 2>&1 || true
done

echo
echo "==================== SCOREBOARD ===================="
printf '%-22s %-4s %6s\n' PHASE RES TIME
for row in "${SCOREBOARD[@]}"; do echo "$row"; done
echo "===================================================="
[ "$OVERALL" -eq 0 ] && echo "ALL PHASES PASSED" || echo "FAILURES PRESENT (see logs/compose.log)"

if [ "${KEEP_STACK:-0}" != "1" ]; then
  $COMPOSE down -v --remove-orphans >/dev/null 2>&1 || true
fi

exit "$OVERALL"
