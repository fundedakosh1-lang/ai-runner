#!/usr/bin/env bash
set -Eeuo pipefail

export GH_TOKEN="${GH_TOKEN:-${GH_PAT:-}}"
AGENT_BRAIN_REPO="${AGENT_BRAIN_REPO:?AGENT_BRAIN_REPO is required}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
LOG_DIR="$HERMES_HOME/logs"
ACCESS_DIR="$HERMES_HOME/access"
PORT="${ACCESS_PORT:-7681}"
TTYD_USER="${ACCESS_USER:-hermes}"

mkdir -p "$LOG_DIR" "$ACCESS_DIR"

log() { printf '[access %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

TTYD_PASS="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
TTYD_BIN="$ACCESS_DIR/ttyd"
CLOUDFLARED_BIN="$ACCESS_DIR/cloudflared"

log "downloading web terminal and tunnel binaries"
gh release download --repo tsl0922/ttyd --pattern 'ttyd.x86_64' --dir "$ACCESS_DIR" --clobber
gh release download --repo cloudflare/cloudflared --pattern 'cloudflared-linux-amd64' --dir "$ACCESS_DIR" --clobber
mv -f "$ACCESS_DIR/ttyd.x86_64" "$TTYD_BIN"
mv -f "$ACCESS_DIR/cloudflared-linux-amd64" "$CLOUDFLARED_BIN"
chmod +x "$TTYD_BIN" "$CLOUDFLARED_BIN"

log "starting web terminal on 127.0.0.1:${PORT}"
setsid "$TTYD_BIN" -W -p "$PORT" -i 127.0.0.1 -c "${TTYD_USER}:${TTYD_PASS}" \
  bash >"$LOG_DIR/ttyd.log" 2>&1 < /dev/null &
sleep 2

log "starting cloudflare quick tunnel"
setsid "$CLOUDFLARED_BIN" tunnel --url "http://127.0.0.1:${PORT}" --no-autoupdate \
  >"$LOG_DIR/cloudflared.log" 2>&1 < /dev/null &

URL=""
for _ in $(seq 1 30); do
  URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/cloudflared.log" 2>/dev/null | head -n1 || true)"
  if [ -n "$URL" ]; then
    break
  fi
  sleep 2
done

if [ -z "$URL" ]; then
  echo "cloudflared did not provide a public URL" >&2
  exit 1
fi

RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-fundedakosh1-lang/ai-runner}/actions/runs/${GITHUB_RUN_ID:-unknown}"
BODY="$(cat <<EOF
Hermes runner web access

URL:
${URL}

Username:
${TTYD_USER}

Password:
${TTYD_PASS}

Run: ${RUN_URL}
EOF
)"

log "creating private access issue"
ISSUE_URL="$(gh issue create --repo "$AGENT_BRAIN_REPO" \
  --title "access ${GITHUB_RUN_ID:-manual} $(date -u +%FT%TZ)" \
  --body "$BODY")"
echo "ACCESS_ISSUE_URL=$ISSUE_URL" >> "${GITHUB_ENV:-/dev/null}"
log "published web access to private memory repository"

current_number="${ISSUE_URL##*/}"
gh issue list --repo "$AGENT_BRAIN_REPO" --state open --limit 100 --json number,title \
  --jq '.[] | select(.title | startswith("access ")) | .number' | while read -r number; do
    if [ "$number" = "$current_number" ]; then
      continue
    fi
    gh issue close "$number" --repo "$AGENT_BRAIN_REPO" \
      --comment "Superseded by #${current_number}" >/dev/null 2>&1 || true
  done