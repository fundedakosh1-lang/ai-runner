#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export PATH="$HOME/.local/bin:$PATH"
export GH_TOKEN="${GH_TOKEN:-${GH_PAT:-}}"

WORKSPACE="${WORKSPACE:-$HOME/workspace}"
AGENT_BRAIN_REPO="${AGENT_BRAIN_REPO:?AGENT_BRAIN_REPO is required}"
GH_PAT="${GH_PAT:?GH_PAT is required}"
ENV_FILE="${GITHUB_ENV:-/dev/null}"

log() { printf '[setup %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

GIT_AUTH_HEADER="http.https://github.com/.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_PAT" | base64 -w0)"

log "Installing system dependencies"
sudo apt-get update -qq
sudo apt-get install -y -qq git curl jq tmux sqlite3 rsync ca-certificates openssh-server

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required on the runner" >&2
  exit 1
fi

log "Cloning memory repository"
if [ -d "$WORKSPACE/.git" ]; then
  git -C "$WORKSPACE" remote set-url origin "https://github.com/${AGENT_BRAIN_REPO}.git"
  git -c "$GIT_AUTH_HEADER" -C "$WORKSPACE" fetch --depth=1 origin main
  git -C "$WORKSPACE" reset --hard origin/main
else
  git -c "$GIT_AUTH_HEADER" clone --depth=1 "https://github.com/${AGENT_BRAIN_REPO}.git" "$WORKSPACE"
fi

HERMES_BIN="$HERMES_HOME/hermes-agent/.hermes/bin/hermes"
if [ ! -x "$HERMES_BIN" ]; then
  log "Installing Hermes Agent"
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | \
    bash -s -- --non-interactive --skip-browser --skip-computer-use
fi

if [ ! -x "$HERMES_BIN" ]; then
  HERMES_BIN="$(command -v hermes || true)"
fi
if [ -z "${HERMES_BIN:-}" ] || [ ! -x "$HERMES_BIN" ]; then
  echo "Hermes binary not found after install" >&2
  exit 1
fi
echo "HERMES_BIN=$HERMES_BIN" >> "$ENV_FILE"

if [ -n "${PREVIOUS_RUN_ID:-}" ] && [ "$PREVIOUS_RUN_ID" != "0" ]; then
  log "Waiting for previous run $PREVIOUS_RUN_ID to finish"
  previous_done=false
  for _ in $(seq 1 150); do
    status="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${PREVIOUS_RUN_ID}" --jq '.status' 2>/dev/null || true)"
    if [ "$status" = "completed" ]; then
      previous_done=true
      break
    fi
    sleep 10
  done
  if [ "$previous_done" != true ]; then
    echo "Previous run did not finish within 25 minutes" >&2
    exit 1
  fi
  log "Previous run finished"
fi

log "Pulling latest memory"
git -c "$GIT_AUTH_HEADER" -C "$WORKSPACE" fetch --depth=1 origin main
git -C "$WORKSPACE" reset --hard origin/main

log "Restoring Hermes state"
mkdir -p "$HERMES_HOME" "$HERMES_HOME/memories" "$HERMES_HOME/skills" \
  "$HERMES_HOME/sessions" "$HERMES_HOME/cron" "$HERMES_HOME/logs"
if [ -d "$WORKSPACE/.hermes" ]; then
  for dir in memories sessions cron; do
    if [ -d "$WORKSPACE/.hermes/$dir" ]; then
      mkdir -p "$HERMES_HOME/$dir"
      rsync -a "$WORKSPACE/.hermes/$dir/" "$HERMES_HOME/$dir/"
    fi
  done
  for file in SOUL.md config.yaml state.db; do
    if [ -f "$WORKSPACE/.hermes/$file" ]; then
      cp -f "$WORKSPACE/.hermes/$file" "$HERMES_HOME/$file"
    fi
  done
fi
if [ -d "$WORKSPACE/hermes_data" ]; then
  mkdir -p "$HOME/hermes_data"
  rsync -a "$WORKSPACE/hermes_data/" "$HOME/hermes_data/"
fi

if [ ! -f "$HERMES_HOME/SOUL.md" ]; then
  cat > "$HERMES_HOME/SOUL.md" <<'EOF'
# Hermes

You are Hermes, a capable autonomous agent running on a GitHub Actions runner.
Be direct, accurate, and useful. Use the tools available to you to complete the
user's request, and keep responses concise unless detail is requested.
EOF
fi

BASE_URL="${LLM_BASE_URL%/}"
case "$BASE_URL" in
  */v1) ;;
  *) BASE_URL="${BASE_URL}/v1" ;;
esac
MODEL="${LLM_MODEL:-gpt-6.1-sol}"

log "Writing Hermes configuration"
umask 077
{
  printf 'HERMES_MODEL_API_KEY=%s\n' "$LLM_API_KEY"
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TG_BOT_TOKEN"
  printf 'TELEGRAM_ALLOW_ALL_USERS=true\n'
  printf 'TELEGRAM_ALLOWED_USERS=*\n'
  printf 'GATEWAY_ALLOW_ALL_USERS=true\n'
  printf 'GATEWAY_ALLOWED_USERS=*\n'
} > "$HERMES_HOME/.env"
chmod 600 "$HERMES_HOME/.env"

cat > "$HERMES_HOME/config.yaml" <<EOF
model:
  provider: xingchiapi
  default: "${MODEL}"
  base_url: "${BASE_URL}"
  api_mode: codex_responses
  api_key: "\${HERMES_MODEL_API_KEY}"
  streaming: true
providers:
  xingchiapi:
    api: "${BASE_URL}"
    key_env: HERMES_MODEL_API_KEY
    transport: codex_responses
    default_model: "${MODEL}"
    extra_headers:
      User-Agent: "claude-cli/1.0.0 (external, cli)"
      x-app: "cli"
      anthropic-version: "2023-06-01"
      x-stainless-lang: "js"
      x-stainless-package-version: "0.60.0"
      x-stainless-os: "Linux"
      x-stainless-arch: "x64"
      x-stainless-runtime: "node"
      x-stainless-runtime-version: "v22.14.0"
telemetry:
  shared_metrics:
    enabled: false
    send: false
updates:
  check: false
onboarding:
  run: false
  profile_build: "off"
gateway:
  trust_env: false
platforms:
  telegram:
    enabled: true
    dm_policy: open
    group_policy: open
EOF
chmod 600 "$HERMES_HOME/config.yaml"

if ! "$HERMES_BIN" config get model.provider >/dev/null 2>&1; then
  echo "Hermes config validation failed" >&2
  exit 1
fi

log "Setup complete (model=${MODEL}, base_url=${BASE_URL})"
