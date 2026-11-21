#!/usr/bin/env bash
set -Eeuo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
current="${GITHUB_RUN_ID:-0}"
output="${GITHUB_OUTPUT:-/dev/null}"

if [ "${RELAY:-false}" = "true" ] || [ "${FORCE:-false}" = "true" ]; then
  echo "Relay/force run; skipping duplicate check"
  echo "skip=false" >> "$output"
  exit 0
fi

for status in in_progress queued waiting; do
  active="$(gh api "repos/${repo}/actions/workflows/hermes.yml/runs?status=${status}&per_page=100" \
    --jq ".workflow_runs[] | select(.id != ${current}) | .id")"
  if [ -n "$active" ]; then
    echo "Another Hermes run is active (${status}): $(echo "$active" | tr '\n' ' ')"
    echo "skip=true" >> "$output"
    exit 0
  fi
done

echo "No other Hermes run is active; proceeding"
echo "skip=false" >> "$output"
