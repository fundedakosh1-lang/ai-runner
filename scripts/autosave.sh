#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="${WORKSPACE:-$HOME/workspace}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
AGENT_BRAIN_REPO="${AGENT_BRAIN_REPO:?AGENT_BRAIN_REPO is required}"
GH_PAT="${GH_PAT:?GH_PAT is required}"
GIT_AUTH_HEADER="http.https://github.com/.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_PAT" | base64 -w0)"

log() { printf '[autosave %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

sync_state() {
  mkdir -p "$WORKSPACE/.hermes"
  for dir in memories sessions cron; do
    if [ -d "$HERMES_HOME/$dir" ]; then
      mkdir -p "$WORKSPACE/.hermes/$dir"
      rsync -a --delete "$HERMES_HOME/$dir/" "$WORKSPACE/.hermes/$dir/"
    fi
  done
  for file in SOUL.md config.yaml; do
    if [ -f "$HERMES_HOME/$file" ]; then
      cp -f "$HERMES_HOME/$file" "$WORKSPACE/.hermes/$file"
    fi
  done
  if [ -f "$HERMES_HOME/state.db" ]; then
    if command -v sqlite3 >/dev/null 2>&1; then
      sqlite3 "$HERMES_HOME/state.db" ".backup '$WORKSPACE/.hermes/state.db'" || \
        cp -f "$HERMES_HOME/state.db" "$WORKSPACE/.hermes/state.db"
    else
      cp -f "$HERMES_HOME/state.db" "$WORKSPACE/.hermes/state.db"
    fi
  fi
  if [ -d "$HOME/hermes_data" ]; then
    mkdir -p "$WORKSPACE/hermes_data"
    rsync -a --delete "$HOME/hermes_data/" "$WORKSPACE/hermes_data/"
  fi
}

save_once() {
  sync_state
  cd "$WORKSPACE"
  git add -A
  if git diff --cached --quiet; then
    log "no changes"
    return 0
  fi
  git -c user.name="Hermes Autosave" -c user.email="hermes@localhost" \
    commit -m "autosave $(date -u +%FT%TZ)" >/dev/null

  for attempt in 1 2 3; do
    if git -c "$GIT_AUTH_HEADER" push origin HEAD:main >/dev/null 2>&1; then
      log "pushed"
      return 0
    fi
    log "push failed (attempt ${attempt}/3); rebasing"
    git -c "$GIT_AUTH_HEADER" pull --rebase origin main >/dev/null 2>&1 || \
      git rebase --abort >/dev/null 2>&1 || true
    sleep 5
  done
  log "push failed after 3 attempts"
  return 1
}

if [ "${1:-}" = "--once" ]; then
  save_once
  exit $?
fi

while true; do
  sleep "${AUTOSAVE_INTERVAL_SECONDS:-600}"
  save_once || log "autosave failed; retrying next interval"
done
