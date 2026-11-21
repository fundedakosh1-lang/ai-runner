#!/usr/bin/env bash
set -Eeuo pipefail

export GH_TOKEN="${GH_TOKEN:-${GH_PAT:-}}"
GH_PAT="${GH_PAT:?GH_PAT is required}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
REF="${GITHUB_REF_NAME:-main}"
WORKFLOW="hermes.yml"
GRACE="${RELAY_GRACE_SECONDS:-900}"

log() { printf '[relay %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

if [ ! -f "${RUNNER_TEMP:-/tmp}/relay-enabled" ]; then
  log "No relay marker; gateway did not start, skipping dispatch"
  exit 0
fi

PAYLOAD="$(jq -n --arg ref "$REF" --arg previous "${GITHUB_RUN_ID:-}" \
  '{ref: $ref, inputs: {relay: "true", previous_run_id: $previous}}')"

dispatched=false
for attempt in 1 2 3; do
  if curl -fsS -X POST \
    -H "Authorization: Bearer ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches" \
    -d "$PAYLOAD" >/dev/null; then
    dispatched=true
    break
  fi
  log "dispatch failed (attempt ${attempt}/3)"
  sleep 10
done

if [ "$dispatched" != true ]; then
  echo "Failed to dispatch the next Hermes run" >&2
  exit 1
fi

log "Next run dispatched; keeping the current gateway alive for ${GRACE}s"
sleep "$GRACE"

log "Stopping autosave loop"
pkill -f 'scripts/autosave.sh' >/dev/null 2>&1 || true
sleep 2

log "Final autosave"
bash scripts/autosave.sh --once || log "Final autosave failed"

log "Stopping gateway and web access"
tmux kill-session -t hermes >/dev/null 2>&1 || true
pkill -f 'hermes gateway run' >/dev/null 2>&1 || true
pkill -f 'ttyd.*7681' >/dev/null 2>&1 || true
pkill -f 'cloudflared.*tunnel' >/dev/null 2>&1 || true
pkill -f 'sshd' >/dev/null 2>&1 || true

log "Relay complete"
