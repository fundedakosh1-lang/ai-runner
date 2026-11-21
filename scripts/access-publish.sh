#!/usr/bin/env bash
# access-publish.sh — web terminal (HTTP) + SSH (TCP tunnel) URLlarini chiqaradi
set -Eeuo pipefail

export GH_TOKEN="${GH_TOKEN:-${GH_PAT:-}}"
AGENT_BRAIN_REPO="${AGENT_BRAIN_REPO:?AGENT_BRAIN_REPO is required}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
LOG_DIR="$HERMES_HOME/logs"
ACCESS_DIR="$HERMES_HOME/access"
PORT="${ACCESS_PORT:-7681}"
TTYD_USER="${ACCESS_USER:-hermes}"
SSH_PORT=2222

mkdir -p "$LOG_DIR" "$ACCESS_DIR"

log() { printf '[access %s] %s\n' "$(date -u +%FT%TZ)" "$*" }

# --- binlar ---------------------------------------------------------------
TTYD_PASS="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
TTYD_BIN="$ACCESS_DIR/ttyd"
CLOUDFLARED_BIN="$ACCESS_DIR/cloudflared"

log "binlar yuklanmoqda"
gh release download --repo tsl0922/ttyd --pattern 'ttyd.x86_64' --dir "$ACCESS_DIR" --clobber 2>/dev/null || true
gh release download --repo cloudflare/cloudflared --pattern 'cloudflared-linux-amd64' --dir "$ACCESS_DIR" --clobber 2>/dev/null || true
mv -f "$ACCESS_DIR/ttyd.x86_64" "$TTYD_BIN" 2>/dev/null || true
mv -f "$ACCESS_DIR/cloudflared-linux-amd64" "$CLOUDFLARED_BIN" 2>/dev/null || true
chmod +x "$TTYD_BIN" "$CLOUDFLARED_BIN" 2>/dev/null || true

# --- web terminal (HTTP tunnel) ------------------------------------------
log "web terminal 127.0.0.1:${PORT} da ishga tushmoqda"
env -i HOME="$HOME" USER="${USER:-runner}" LOGNAME="${LOGNAME:-runner}" \
  PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=xterm-256color SHELL=/bin/bash \
  setsid "$TTYD_BIN" -W -p "$PORT" -i 127.0.0.1 -c "${TTYD_USER}:${TTYD_PASS}" \
  bash -l >"$LOG_DIR/ttyd.log" 2>&1 < /dev/null &
sleep 2

log "cloudflared HTTP tunnel ishga tushmoqda"
env -i HOME="$HOME" USER="${USER:-runner}" LOGNAME="${LOGNAME:-runner}" \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  setsid "$CLOUDFLARED_BIN" tunnel --url "http://127.0.0.1:${PORT}" --no-autoupdate \
  >"$LOG_DIR/cloudflared.log" 2>&1 < /dev/null &

URL=""
for _ in $(seq 1 30); do
  URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/cloudflared.log" 2>/dev/null | head -n1 || true)"
  if [ -n "$URL" ]; then break; fi
  sleep 2
done

# --- sshd (TCP tunnel) ---------------------------------------------------
log "sshd 127.0.0.1:${SSH_PORT} da ishga tushmoqda"
# sshd mavjudligini tekshirish
if ! command -v sshd >/dev/null 2>&1; then
  log "sshd topilmadi, o'rnatilmoqda (sudo kerak bo'lishi mumkin)"
  sudo apt-get update -qq 2>/dev/null || true
  sudo apt-get install -y -qq openssh-server 2>/dev/null || true
fi

# host kalitlarini yaratish
sudo mkdir -p /run/sshd
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  sudo ssh-keygen -A 2>/dev/null || true
fi

# PAT orqali autentifikatsiya uchun authorized_keys hosil qilamiz
# Foydalanuvchi: root (runner sistemasi). Parol bo'liq PAT.
echo "PermitRootLogin yes" | sudo tee -a /etc/ssh/sshd_config >/dev/null 2>&1 || true
echo "PasswordAuthentication yes" | sudo tee -a /etc/ssh/sshd_config >/dev/null 2>&1 || true
echo "PubkeyAuthentication yes" | sudo tee -a /etc/ssh/sshd_config >/dev/null 2>&1 || true

# root parolini PAT ga o'rnatamiz (PAT bo'yicha sshga kirish)
if [ -n "${GH_PAT:-}" ]; then
  echo "root:${GH_PAT}" | sudo chpasswd 2>/dev/null || true
fi

# sshd ni boshqarish (oldindan ishlagan bo'lsa qayta boshlaymiz)
sudo pkill sshd 2>/dev/null || true
sudo /usr/sbin/sshd -p "$SSH_PORT" 2>/dev/null || sudo sshd -p "$SSH_PORT" 2>/dev/null || true
sleep 2

# sshd ishlayotganligini tekshirish
SSHD_OK=false
if sudo ss -ltnp 2>/dev/null | grep -q ":${SSH_PORT} "; then
  SSHD_OK=true
fi

# --- cloudflared TCP tunnel (SSH) ----------------------------------------
log "cloudflared TCP tunnel ssh://localhost:${SSH_PORT} uchun ishga tushmoqda"
env -i HOME="$HOME" USER="${USER:-runner}" LOGNAME="${LOGNAME:-runner}" \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  setsid "$CLOUDFLARED_BIN" tunnel --url "tcp://localhost:${SSH_PORT}" --no-autoupdate \
  >"$LOG_DIR/cloudflared-ssh.log" 2>&1 < /dev/null &

# public URL ni chiqarish (30 soniyacha kutamiz)
SSH_URL=""
for _ in $(seq 1 30); do
  # 1) log'dan yechish
  SSH_URL="$(grep -oE 'tcp://[a-z0-9-]+\.trycloudflare\.com:[0-9]+' "$LOG_DIR/cloudflared-ssh.log" 2>/dev/null | head -n1 || true)"
  # 2) 4040 API'dan yechish
  if [ -z "$SSH_URL" ]; then
    SSH_API="$(curl -s http://127.0.0.1:4040/api/tunnels 2>/dev/null | python3 -c "
import json,sys,re
try:
    data=json.load(sys.stdin)
except Exception:
    sys.exit(1)
for t in data.get('tunnels',[]):
    if t.get('proto')=='tcp':
        pub=t.get('public_url','')
        m=re.match(r'tcp://([^/:]+):(\d+)',pub)
        if m:
            print(f\"{m.group(1)}:{m.group(2)}\")
        elif pub:
            print(pub)
        break
" 2>/dev/null || true)"
    if [ -n "$SSH_API" ]; then SSH_URL="$SSH_API"; break; fi
  fi
  if [ -n "$SSH_URL" ]; then break; fi
  sleep 2
done

# --- xabar tayyorlash ------------------------------------------------------
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-fundedakosh1-lang/ai-runner}/actions/runs/${GITHUB_RUN_ID:-unknown}"

if [ -z "$URL" ]; then
  echo "cloudflared HTTP URL topilmadi" >&2
  exit 1
fi

SSH_BLOCK=""
if [ -n "$SSH_URL" ]; then
  # tcp://host:port -> host:port
  SSH_HOSTPORT="${SSH_URL#tcp://}"
  SSH_BLOCK="

SSH Access:
Ulanish: ssh -p ${SSH_PORT} root@${SSH_HOSTPORT}
Parol: GH_PAT (sizning GitHub personal access token)
(eslatma: TCP tunnel har bir urinishda yangi URL oladi)
"
else
  SSH_BLOCK="

SSH Access:
(bu urinishda TCP tunnel URL topilmadi; keyingi urinishda qayta urinib ko'ring yoki web terminaldan foydalaning)
"
fi

BODY="$(cat <<EOF
Hermes runner kirish

Web Terminal:
URL:
${URL}

Foydalanuvchi:
${TTYD_USER}

Parol:
${TTYD_PASS}

Run: ${RUN_URL}
${SSH_BLOCK}
EOF
)"

log "asaxiy issue yasalmoqda"
ISSUE_URL="$(gh issue create --repo "$AGENT_BRAIN_REPO" \
  --title "access ${GITHUB_RUN_ID:-manual} $(date -u +%FT%TZ)" \
  --body "$BODY")"
echo "ACCESS_ISSUE_URL=$ISSUE_URL" >> "${GITHUB_ENV:-/dev/null}"
log "ishlading: $ISSUE_URL"

current_number="${ISSUE_URL##*/}"
gh issue list --repo "$AGENT_BRAIN_REPO" --state open --limit 100 --json number,title \
  --jq '.[] | select(.title | startswith("access ")) | .number' | while read -r number; do
    if [ "$number" = "$current_number" ]; then continue; fi
    gh issue close "$number" --repo "$AGENT_BRAIN_REPO" \
      --comment "Yangisiga o'tildi: #${current_number}" >/dev/null 2>&1 || true
  done