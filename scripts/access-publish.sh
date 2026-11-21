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

log() { printf '[access %s] %s\n' "$(date -u +%FT%TZ)" "$*" }

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
env -i HOME="$HOME" USER="${USER:-runner}" LOGNAME="${LOGNAME:-runner}" \
  PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=xterm-256color SHELL=/bin/bash \
  setsid "$TTYD_BIN" -W -p "$PORT" -i 127.0.0.1 -c "${TTYD_USER}:${TTYD_PASS}" \
  bash -l >"$LOG_DIR/ttyd.log" 2>&1 < /dev/null &
sleep 2

log "starting cloudflare quick HTTP tunnel (web terminal)"
env -i HOME="$HOME" USER="${USER:-runner}" LOGNAME="${LOGNAME:-runner}" \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
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

# ALSO start a Cloudflare TCP tunnel for SSH access (port 2222)
# This runs in parallel; its URL will be appended to the access issue
SSH_PORT=2222
log "starting cloudflare quick TCP tunnel (SSH access on port ${SSH_PORT})"
env -i HOME="$HOME" USER="${USER:-runner}" LOGNAME="${LOGNAME:-runner}" \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  setsid "$CLOUDFLARED_BIN" tunnel --url "tcp://localhost:${SSH_PORT}" --no-autoupdate \
  >"$LOG_DIR/cloudflared-ssh.log" 2>&1 < /dev/null &

# Wait briefly for TCP tunnel to also produce a URL
SSH_URL=""
for _ in $(seq 1 15); do
  SSH_URL="$(grep -oE '[a-z0-9-]+:[0-9]+' "$LOG_DIR/cloudflared-ssh.log" 2>/dev/null | head -n1 || true)"
  if [ -n "$SSH_URL" ]; then
    # Convert TCP URL fragment to SSH-friendly format
    # Cloudflare quick TCP tunnel outputs something like: 123.45.67.89:PORT or hostname:PORT
    # We need the full public URL. Let's try via the 4040 API.
    SSH_API="$(curl -s http://127.0.0.1:4040/api/tunnels 2>/dev/null | python3 -c "
import json,sys,re
data=json.load(sys.stdin)
for t in data.get('tunnels',[]):
    if t.get('proto')=='tcp':
        # Format: tcp://hostname:port or tcp://hostname:port -> hostname:port
        pub=t.get('public_url','')
        # Extract hostname:port after tcp://
        m=re.match(r'tcp://([^/:]+):(\d+)',pub)
        if m:
            print(f\"{m.group(1)}:{m.group(2)}\")
        else:
            print(pub)
    else:
        print('skip')
" 2>/dev/null || echo '')"
    if [ -n "$SSH_API" ]; then
      SSH_URL="$SSH_API"
      break
    fi
  fi
  sleep 2
done

# Final fallback: try reading from the API one more time after a delay
if [ -z "$SSH_URL" ]; then
  sleep 3
  SSH_API="$(curl -s http://127.0.0.1:4040/api/tunnels 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
for t in data.get('tunnels',[]):
    if t.get('proto')=='tcp':
        print(t.get('public_url',''))
    else:
        print('skip')
" 2>/dev/null || echo '')"
  if [ -n "$SSH_API" ]; then
    SSH_URL="$SSH_API"
  fi
fi

# Build the SSH access line for the issue body
SSH_ACCESS_BLOCK=""
if [ -n "$SSH_URL" ]; then
  SSH_ACCESS_BLOCK="

SSH Access:
Connect via: ssh -p ${SSH_PORT} runner@${SSH_URL}
(Use your PAT/GH_TOKEN as authentication; the tunnel terminates at the GitHub runner.)
"
else
  SSH_ACCESS_BLOCK="

SSH Access:
(Cloudflare TCP tunnel URL not available this run; try again later or use the web terminal above.)
"
fi

RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-fundedakosh1-lang/ai-runner}/actions/runs/${GITHUB_RUN_ID:-unknown}"
BODY="$(cat <<EOF
Hermes runner access

Web Terminal:
URL:
${URL}

Username:
${TTYD_USER}

Password:
${TTYD_PASS}

Run: ${RUN_URL}
${SSH_ACCESS_BLOCK}
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