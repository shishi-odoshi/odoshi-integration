# otp-rails-integration

The full-stack integration harness for the [shishi-odoshi](https://github.com/shishi-odoshi)
otp-rails project — the first environment that runs the **entire stack at once**
and applies chaos across the seams:

- **[otp-rails](https://github.com/shishi-odoshi/otp-rails)** — the slim
  supervisor (`bin/supervise`) owning the Rails app's `web` and `jobs` children.
- **[otp-rails-template](https://github.com/shishi-odoshi/otp-rails-template)** —
  `template.rb` generates the supervised Rails app **fresh on every run**
  (nothing generated is committed here, mirroring the template repo's no-drift rule).
- **[beam](https://github.com/shishi-odoshi/beam)** — the Elixir sidecar:
  a Solid Queue worker on the designated `elixir` queue, and an
  ActionCable-compatible cable server fed from the Solid Cable schema.
- **[otp-rails-resilience](https://github.com/shishi-odoshi/otp-rails-resilience)**
  (unpublished, consumed via git source) — telemetry bridge,
  `Rails.supervisor.restart!`, breakers, `bin/rails boot:check`.

## Run it

```
./scripts/integration.sh          # CI runs exactly this
KEEP_STACK=1 ./scripts/integration.sh   # leave the stack up for poking
```

Requires Docker with Compose v2. The script builds the images, stands up the
stack, runs the phased test program, prints a scoreboard, and exits non-zero
on any failure. Full stack logs land in `logs/compose.log`.

## The stack

```
postgres:16 ── app_production           (primary; job_markers side-effect table)
            ── app_production_queue     (Solid Queue schema — SHARED Ruby ⇄ beam)
            ── app_production_cable     (Solid Cable schema — Rails writes, beam reads)
            ── app_production_cache

app         rails new … -m template.rb  (fresh every run, -d postgresql)
            └─ bin/supervise (otp-rails, rest_for_one)
               ├─ :web   puma        — HTTP /up probe + §5 heartbeat
               └─ :jobs  bin/jobs    — Solid Queue worker, queues: [default]

beam-queue  OtpRailsBeam.Queue queues: ["elixir"]   — native OTP supervision
beam-cable  OtpRailsBeam.Cable :28080 /cable        — shares SECRET_KEY_BASE
```

beam processes run under **native OTP supervision** inside their nodes; the
node itself is respawned by `beam/start.sh` (the "platform is the final
supervisor" layer otp-rails assigns to Kamal/K8s — SIGKILLing the node is the
chaos input, the loop is the recovery path).

## The seam map

| Seam | Contract | Exercised by |
|---|---|---|
| supervisor ⇄ web/jobs | otp-rails DESIGN §5 heartbeats + probes | phases 2, 3, 7 |
| app code ⇄ supervisor | §9 control socket (`Rails.supervisor.restart!`) via otp-rails-resilience | phase 6 |
| Rails ⇄ beam queue | Solid Queue Postgres schema, routing **by queue** (`default` = Ruby, `elixir` = beam) | phases 1, 3, 4 |
| Rails ⇄ beam cable | Solid Cable schema + Turbo signed stream names keyed off shared `SECRET_KEY_BASE` | phases 1, 2, 5 |
| dead-worker semantics | Solid Queue pruning: claims of a SIGKILLed worker **fail** with `ProcessPrunedError` ([otp-rails#41](https://github.com/shishi-odoshi/otp-rails/issues/41) — asserted, not fought) | phase 4 |

Side effects are observable by construction: the shared test ActiveJob
(`IntegrationMarkerJob` / `SlowMarkerJob`) writes a `job_markers` row tagged
with the runtime that executed it (`ruby` or `beam`), so routing,
exactly-once, and duplicate detection are plain SQL.

## The test program

| Phase | Asserts |
|---|---|
| 1 steady state | `/up` 200; 20 jobs to each queue drain **exactly once** on the right runtime; a Rails broadcast reaches a WebSocket client subscribed through beam (Turbo signed stream) |
| 2 chaos: web | `kill -9` puma master → `/up` back < 10s (template's own chaos task) → cable round-trip still works |
| 3 chaos: Ruby jobs | `kill -9` bin/jobs → supervisor respawns < 10s → `default` drains; `elixir` jobs in flight throughout are untouched |
| 4 chaos: beam queue | `kill -9` the BEAM node mid-burst → claimed jobs become **FAILED with `ProcessPrunedError`** after prune; unclaimed jobs drain once the worker returns; `default` unaffected |
| 5 chaos: cable | kill beam cable mid-subscription → client reconnects → **no replay** of pre-kill broadcasts → new broadcasts delivered |
| 6 resilience in situ | `bin/rails boot:check` passes on the generated app; `Rails.supervisor.restart!(:jobs)` **from app code** (a controller in the supervised web child) replaces the jobs child — the first end-to-end exercise of the §9 control path |
| 7 clean teardown | `SIGTERM` to the supervisor → exit 0, zero orphaned app processes (`ps` audit), control socket unlinked |

A compact scoreboard (phase, pass/fail, timing) prints at the end of every run.

## Harness-specific configuration (documented deltas)

The generated app is pure template output plus these patches (`app/patches/`):

- `database.yml` → the 4-database Postgres production shape.
- `queue.yml` → Ruby workers pinned to `queues: [default]` (the generated `*`
  would let Ruby claim beam's designated queue).
- `Gemfile` += `otp-rails-resilience` from git (unpublished).
- Integration surface: marker model/jobs, `/integration/*` endpoints
  (enqueue / broadcast / signed_stream / restart_jobs) so every stimulus
  originates inside supervised production processes.
- `production.rb`: `force_ssl`/`assume_ssl` off (plain HTTP inside the compose
  network), and accelerated Solid Queue liveness
  (`process_heartbeat_interval` 3s / `process_alive_threshold` 15s) so phase 4's
  prune semantics fit CI timescales. beam's worker heartbeats on the same 3s cadence.
