#!/usr/bin/env bash
set -Eeuo pipefail

export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export PATH="$HOME/.local/bin:$PATH"
export HERMES_GATEWAY_PLATFORM_CONNECT_TIMEOUT="${HERMES_GATEWAY_PLATFORM_CONNECT_TIMEOUT:-120}"
umask 077
cd "$HOME"

HERMES_BIN="${HERMES_BIN:-$HERMES_HOME/hermes-agent/.hermes/bin/hermes}"
if [ ! -x "$HERMES_BIN" ]; then
  HERMES_BIN="$(command -v hermes || true)"
fi
if [ -z "${HERMES_BIN:-}" ] || [ ! -x "$HERMES_BIN" ]; then
  echo "Hermes binary not found" >&2
  exit 1
fi

exec "$HERMES_BIN" gateway run --force --accept-hooks -v
