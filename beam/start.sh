#!/bin/sh
# Respawn loop for the BEAM node. Inside the node, queue/cable processes are
# under NATIVE OTP supervision; this loop is the "platform as final
# supervisor" layer odoshi assigns to Kamal/K8s — it brings the node back
# after the chaos phases SIGKILL it (pkill -9 beam.smp).
cd /runner || exit 1
while true; do
  echo "[start.sh] starting BEAM node (ROLE=${ROLE:-unset})"
  mix run --no-halt
  echo "[start.sh] BEAM node exited; respawning in 2s"
  sleep 2
done
