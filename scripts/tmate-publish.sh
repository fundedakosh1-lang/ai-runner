#!/usr/bin/env bash
set -Eeuo pipefail

export GH_TOKEN="${GH_TOKEN:-${GH_PAT:-}}"
AGENT_BRAIN_REPO="${AGENT_BRAIN_REPO:?AGENT_BRAIN_REPO is required}"
SOCKET="/tmp/tmate.sock"
LOG_DIR="${HERMES_HOME:-$HOME/.hermes}/logs"
mkdir -p "$LOG_DIR"

log() { printf '[tmate %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

log "tmate binary: $(command -v tmate || echo missing)"
if tmate -S "$SOCKET" new-session -d; then
  log "tmate session started"
else
  log "tmate new-session failed"
fi
log "waiting for tmate-ready"
for _ in $(seq 1 15); do
  if timeout 10 tmate -S "$SOCKET" wait tmate-ready >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
log "tmate ready wait finished"

SSH_ADDR="$(tmate -S "$SOCKET" display -p '#{tmate_ssh}' 2>/dev/null || true)"
WEB_ADDR="$(tmate -S "$SOCKET" display -p '#{tmate_web}' 2>/dev/null || true)"

if [ -z "$SSH_ADDR" ]; then
  echo "tmate did not provide an SSH address" >&2
  exit 1
fi

RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-fundedakosh1-lang/ai-runner}/actions/runs/${GITHUB_RUN_ID:-unknown}"
BODY="$(cat <<EOF
Hermes runner tmate access

SSH:
\`\`\`
${SSH_ADDR}
\`\`\`

Web:
${WEB_ADDR}

Run: ${RUN_URL}
EOF
)"

log "creating private tmate issue"
ISSUE_URL="$(gh issue create --repo "$AGENT_BRAIN_REPO" \
  --title "tmate ${GITHUB_RUN_ID:-manual} $(date -u +%FT%TZ)" \
  --body "$BODY")"
echo "TMATE_ISSUE_URL=$ISSUE_URL" >> "${GITHUB_ENV:-/dev/null}"
log "published tmate access to private memory repository"

current_number="${ISSUE_URL##*/}"
gh issue list --repo "$AGENT_BRAIN_REPO" --state open --limit 100 --json number,title \
  --jq '.[] | select(.title | startswith("tmate ")) | .number' | while read -r number; do
    if [ "$number" = "$current_number" ]; then
      continue
    fi
    gh issue close "$number" --repo "$AGENT_BRAIN_REPO" \
      --comment "Superseded by #${current_number}" >/dev/null 2>&1 || true
  done
