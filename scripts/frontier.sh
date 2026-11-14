#!/usr/bin/env bash
# Wayfinding helper for the local-markdown tracker.
#
#   ./scripts/frontier.sh                 # list the frontier: open, unblocked, unclaimed
#   ./scripts/frontier.sh --all           # list every ticket with its state
#   ./scripts/frontier.sh --map           # print the map body
#
# Conventions (see .scratch/vitals/map.md and the local tracker doc):
#   .scratch/<effort>/map.md                          the map
#   .scratch/<effort>/issues/NN-<slug>.md             child tickets
#   Ticket header lines: Type:, Status:, Blocked by:   (Blocked by: NN, NN)
#   A ticket is unblocked when every ticket it lists is resolved.
set -euo pipefail

EFFORT="vitals"
MODE="frontier"
for arg in "$@"; do
  case "$arg" in
    --all) MODE="all" ;;
    --map) MODE="map" ;;
    *)    EFFORT="$arg" ;;
  esac
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/.scratch/$EFFORT/issues"

[ -d "$DIR" ] || { echo "no such effort: $EFFORT" >&2; exit 1; }

status_of() { grep -m1 '^Status:' "$1" | sed 's/^Status:[[:space:]]*//' | tr -d '[:space:]'; }
type_of()   { grep -m1 '^Type:'   "$1" | sed 's/^Type:[[:space:]]*//'   | tr -d '[:space:]'; }
blocked_by() {
  local raw
  raw="$(grep -m1 '^Blocked by:' "$1" | sed 's/^Blocked by:[[:space:]]*//' | tr -d '[:space:]')"
  [ -z "$raw" ] || [ "$raw" = "none" ] && echo "" || echo "$raw"
}

is_resolved() {
  local n="$1" f
  f="$(ls "$DIR/$n-"*.md 2>/dev/null | head -1)"
  [ -n "$f" ] && [ "$(status_of "$f")" = "resolved" ]
}

if [ "$MODE" = "map" ]; then
  cat "$ROOT/.scratch/$EFFORT/map.md"; exit 0
fi

if [ "$MODE" = "all" ]; then
  for f in "$DIR"/*.md; do
    printf '%-44s %-10s %-10s %s\n' "$(basename "$f")" "$(type_of "$f")" "$(status_of "$f")" "$(blocked_by "$f" | tr ',' ' ')"
  done
  exit 0
fi

frontier=()
for f in "$DIR"/*.md; do
  st="$(status_of "$f")"
  [ "$st" = "open" ] || continue
  blocked=""
  for dep in $(blocked_by "$f" | tr ',' ' '); do
    [ -n "$dep" ] && ! is_resolved "$dep" && blocked="yes"
  done
  [ -z "$blocked" ] && frontier+=("$(basename "$f" .md)|$(type_of "$f")")
done

if [ ${#frontier[@]} -eq 0 ]; then
  echo "frontier is empty — nothing takeable right now."
  exit 0
fi

echo "frontier (open, unblocked, unclaimed) — first by number wins:"
for item in "${frontier[@]}"; do
  printf '  %-44s [%s]\n' "${item%%|*}" "${item##*|}"
done
