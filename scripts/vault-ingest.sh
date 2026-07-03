#!/usr/bin/env bash
#
# Ingest the plaintext vault mirror into Cognee.
#
# Principles:
#   - Whitelist, not blacklist: new folders are OUT by default (keep private data safe).
#   - Hash-based change detection (SHA-256), because sync tools bump mtimes without
#     changing content.
#   - One `cognify` per run (the expensive LLM step), not one per file.
#   - State is written only on success (`set -e`); reruns are cost-neutral thanks to
#     Cognee's add-dedup.
#
# Adjust the paths and WHITELIST below to your setup.
set -euo pipefail

VAULT="/srv/docker/livesync-bridge/data/vault"
STATE="/srv/docker/cognee/ingest-state.txt"
API="http://127.0.0.1:8010/api/v1"
DATASET="obsidian-vault"

# ── Whitelist: ONLY these folders/files get ingested. ──
# Paths are relative to $VAULT. Add folders deliberately, ideally one at a time on the
# initial load to spread out the embedding work.
WHITELIST=(
  "Notes"
  "Projects"
  "Journal"
  "README.md"
)
# Exceptions within the whitelist:
EXCLUDES=( "./Notes/_templates/*" )

cd "$VAULT"
current=$(mktemp)
trap 'rm -f "$current"' EXIT

# Build find arguments from whitelist + excludes
find_args=()
for entry in "${WHITELIST[@]}"; do
  find_args+=( "./${entry}" )
done
exclude_args=()
for ex in "${EXCLUDES[@]}"; do
  exclude_args+=( -not -path "$ex" )
done

find "${find_args[@]}" -type f -name "*.md" "${exclude_args[@]}" \
  -print0 2>/dev/null | xargs -0 -r sha256sum | LC_ALL=C sort > "$current"

touch "$STATE"

# New or changed = lines (hash+path) present now but missing from the old state
mapfile -t changed < <(comm -23 "$current" <(LC_ALL=C sort "$STATE") | sed 's/^[a-f0-9]*  //')

# Deleted paths: log only (v1: no automatic forget)
comm -13 <(sed 's/^[a-f0-9]*  //' "$STATE" | LC_ALL=C sort -u) \
         <(sed 's/^[a-f0-9]*  //' "$current" | LC_ALL=C sort -u) \
  | while read -r gone; do echo "$(date -Is) DELETED (orphaned in graph): $gone"; done

if [ ${#changed[@]} -eq 0 ]; then
  echo "$(date -Is) no changes"
  exit 0
fi

for f in "${changed[@]}"; do
  curl -sf -X POST "$API/add" \
    -F "data=@${f}" \
    -F "datasetName=${DATASET}" > /dev/null \
    && echo "$(date -Is) added: $f"
done

echo "$(date -Is) cognify for ${#changed[@]} file(s) ..."
curl -sf -X POST "$API/cognify" \
  -H "Content-Type: application/json" \
  -d "{\"datasets\": [\"${DATASET}\"]}" > /dev/null
echo "$(date -Is) done"

cp "$current" "$STATE"
