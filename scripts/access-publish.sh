#!/usr/bin/env bash
set -Eeuo pipefail

# Publish public access to the Hermes runner:
#   1. a browser terminal (ttyd behind a Cloudflare quick HTTP tunnel)
#   2. a real SSH endpoint (sshd behind a bore.pub raw-TCP tunnel)
#
# Why bore.pub and not Cloudflare/localhost.run:
#   Cloudflare quick tunnels and localhost.run only terminate HTTP(S) at their
#   edge, so an SSH client sees "HTTP/1.1 400 Bad Request" instead of an SSH
#   banner. bore.pub proxies raw TCP, which is what sshd needs.

export GH_TOKEN="${GH_TOKEN:-${GH_PAT:-}}"
AGENT_BRAIN_REPO="${AGENT_BRAIN_REPO:?AGENT_BRAIN_REPO is required}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
LOG_DIR="$HERMES_HOME/logs"
ACCESS_DIR="$HERMES_HOME/access"
PORT="${ACCESS_PORT:-7681}"
TTYD_USER="${ACCESS_USER:-hermes}"

SSH_PORT="${SSH_ACCESS_PORT:-2222}"
SSH_USER="${SSH_ACCESS_USER:-root}"
BORE_SERVER="${BORE_SERVER:-bore.pub}"
BORE_PORT="${BORE_PORT:-}"   # empty = let bore.pub assign

mkdir -p "$LOG_DIR" "$ACCESS_DIR"

log() { printf '[access %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

TTYD_PASS="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
TTYD_BIN="$ACCESS_DIR/ttyd"
CLOUDFLARED_BIN="$ACCESS_DIR/cloudflared"
BORE_BIN="$ACCESS_DIR/bore"

fetch() {  # fetch <url> <dest>
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$dest" <<'PY'
import sys, urllib.request
url, dest = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, headers={"User-Agent": "hermes-access-publish"})
with urllib.request.urlopen(req, timeout=120) as r, open(dest, "wb") as f:
    while True:
        chunk = r.read(1 << 16)
        if not chunk:
            break
        f.write(chunk)
PY
  else
    echo "no curl, wget or python3 available to download $url" >&2
    return 1
  fi
}

asset_url() {  # asset_url <owner/repo> <version|latest> <name-pattern>
  local repo="$1" ver="$2" pattern="$3" url
  if [ "$ver" = "latest" ]; then
    url="https://api.github.com/repos/${repo}/releases/latest"
  else
    url="https://api.github.com/repos/${repo}/releases/tags/${ver}"
  fi
  python3 - "$url" "$pattern" <<'PY'
import json, re, sys, urllib.request
url, pattern = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                          "User-Agent": "hermes-access-publish"})
data = json.load(urllib.request.urlopen(req, timeout=30))
rx = re.compile(pattern)
for asset in data.get("assets", []):
    if rx.search(asset.get("name", "")):
        print(asset["browser_download_url"])
        break
PY
}

strip_ansi() { sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\[[0-9;]*[0-9;]*m//g' 2>/dev/null || cat; }

log "downloading web terminal and tunnel binaries"
gh release download --repo tsl0922/ttyd --pattern 'ttyd.x86_64' --dir "$ACCESS_DIR" --clobber
gh release download --repo cloudflare/cloudflared --pattern 'cloudflared-linux-amd64' --dir "$ACCESS_DIR" --clobber
mv -f "$ACCESS_DIR/ttyd.x86_64" "$TTYD_BIN"
mv -f "$ACCESS_DIR/cloudflared-linux-amd64" "$CLOUDFLARED_BIN"

if [ ! -x "$ACCESS_DIR/bore" ]; then
  BORE_URL="$(asset_url ekzhang/bore v0.6.0 'bore-v0\.6\.0-x86_64-unknown-linux-musl\.tar\.gz')"
  if [ -z "$BORE_URL" ]; then
    echo "could not resolve the bore release asset" >&2
    exit 1
  fi
  tmp_tgz="$(mktemp)"
  fetch "$BORE_URL" "$tmp_tgz"
  tmp_dir="$(mktemp -d)"
  tar -xzf "$tmp_tgz" -C "$tmp_dir"
  mv -f "$tmp_dir/bore" "$BORE_BIN"
  rm -f "$tmp_tgz"
  rm -rf "$tmp_dir"
fi
chmod +x "$TTYD_BIN" "$CLOUDFLARED_BIN" "$BORE_BIN"

# ---------------------------------------------------------------- web terminal
log "starting web terminal on 127.0.0.1:${PORT}"
env -i HOME="$HOME" USER="${USER:-runner}" LOGNAME="${LOGNAME:-runner}" \
  PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=xterm-256color SHELL=/bin/bash \
  setsid "$TTYD_BIN" -W -p "$PORT" -i 127.0.0.1 -c "${TTYD_USER}:${TTYD_PASS}" \
  bash -l >"$LOG_DIR/ttyd.log" 2>&1 < /dev/null &
sleep 2

log "starting Cloudflare quick HTTP tunnel (web terminal)"
env -i HOME="$HOME" USER="${USER:-runner}" LOGNAME="${LOGNAME:-runner}" \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  setsid "$CLOUDFLARED_BIN" tunnel --url "http://127.0.0.1:${PORT}" --no-autoupdate \
  >"$LOG_DIR/cloudflared.log" 2>&1 < /dev/null &

WEB_URL=""
for _ in $(seq 1 40); do
  WEB_URL="$(strip_ansi < "$LOG_DIR/cloudflared.log" | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | head -n1 || true)"
  [ -n "$WEB_URL" ] && break
  sleep 2
done
if [ -z "$WEB_URL" ]; then
  echo "cloudflared did not provide a public URL" >&2
  exit 1
fi
log "web terminal is public at ${WEB_URL}"

# ------------------------------------------------------------------ SSH via bore
log "preparing sshd on 127.0.0.1:${SSH_PORT}"
sudo mkdir -p /run/sshd
sudo ssh-keygen -A >/dev/null 2>&1 || true

sudo tee /etc/ssh/sshd_config.d/hermes-access.conf >/dev/null <<EOF
Port ${SSH_PORT}
ListenAddress 0.0.0.0
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
EOF

# A password is needed for keyless password auth from any client.
# Use a dedicated, random password and publish it alongside the endpoint.
SSH_PASS="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
echo "${SSH_USER}:${SSH_PASS}" | sudo chpasswd
sudo systemctl restart ssh >/dev/null 2>&1 || sudo service ssh restart >/dev/null 2>&1 || true
sudo /usr/sbin/sshd -p "$SSH_PORT" -o PermitRootLogin=yes -o PasswordAuthentication=yes \
  >/tmp/hermes-sshd.log 2>&1 || true
sleep 2
if ! python3 - "$SSH_PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
except OSError:
    sys.exit(1)
banner = s.recv(64)
s.close()
if not banner.startswith(b"SSH-"):
    sys.exit(1)
PY
then
  echo "sshd is not serving SSH on port ${SSH_PORT}; see /tmp/hermes-sshd.log" >&2
  sudo tail -n 20 /tmp/hermes-sshd.log >&2 2>/dev/null || true
  exit 1
fi
log "sshd listening on ${SSH_PORT}"

log "starting bore tunnel to ${BORE_SERVER}"
bore_args=(local "$SSH_PORT" --to "$BORE_SERVER")
[ -n "$BORE_PORT" ] && bore_args+=(--port "$BORE_PORT")
env -i HOME="$HOME" PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  setsid "$BORE_BIN" "${bore_args[@]}" >"$LOG_DIR/bore.log" 2>&1 < /dev/null &

SSH_ENDPOINT=""
for _ in $(seq 1 40); do
  SSH_ENDPOINT="$(strip_ansi < "$LOG_DIR/bore.log" | grep -oE "listening at ${BORE_SERVER}:[0-9]+" | grep -oE '[0-9]+$' | head -n1 || true)"
  [ -n "$SSH_ENDPOINT" ] && break
  sleep 2
done
if [ -z "$SSH_ENDPOINT" ]; then
  echo "bore did not report a public port" >&2
  exit 1
fi
log "SSH endpoint is ${SSH_USER}@${BORE_SERVER}:${SSH_ENDPOINT}"

# ---------------------------------------------------------------------- publish
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-fundedakosh1-lang/ai-runner}/actions/runs/${GITHUB_RUN_ID:-unknown}"
BODY="$(cat <<EOF
Hermes runner access

Web terminal: ${WEB_URL}
  username: ${TTYD_USER}
  password: ${TTYD_PASS}

SSH: ssh -p ${SSH_ENDPOINT} ${SSH_USER}@${BORE_SERVER}
  password: ${SSH_PASS}

Run: ${RUN_URL}
EOF
)"

log "creating private access issue"
ISSUE_URL="$(gh issue create --repo "$AGENT_BRAIN_REPO" \
  --title "access ${GITHUB_RUN_ID:-manual} $(date -u +%FT%TZ)" \
  --body "$BODY")"
echo "ACCESS_ISSUE_URL=$ISSUE_URL" >> "${GITHUB_ENV:-/dev/null}"
log "published access to ${ISSUE_URL}"

current_number="${ISSUE_URL##*/}"
gh issue list --repo "$AGENT_BRAIN_REPO" --state open --limit 100 --json number,title \
  --jq '.[] | select(.title | startswith("access ")) | .number' | while read -r number; do
    if [ "$number" = "$current_number" ]; then
      continue
    fi
    gh issue close "$number" --repo "$AGENT_BRAIN_REPO" \
      --comment "Superseded by #${current_number}" >/dev/null 2>&1 || true
  done
