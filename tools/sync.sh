#!/usr/bin/env bash
# Pull the latest code: this repo (origin) + the upstream PC translation.
# Usage: bash tools/sync.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UP="$ROOT/upstream/PVZF-Translation"
UP_URL="https://github.com/Teyliu/PVZF-Translation.git"

echo "[sync] this repo: git pull --ff-only"
git -C "$ROOT" pull --ff-only

# Partial clone (full history + tags, file contents fetched on demand) so
# fetch_sources.py can check out the release tag matching an older game version.
if [ -d "$UP/.git" ]; then
  echo "[sync] upstream translation: pull"
  if [ "$(git -C "$UP" rev-parse --is-shallow-repository)" = true ]; then
    git -C "$UP" fetch -q --unshallow --filter=blob:none origin
  fi
  git -C "$UP" fetch -q --tags --prune origin
  git -C "$UP" checkout -q main
  git -C "$UP" merge -q --ff-only origin/main
else
  echo "[sync] upstream translation: partial clone -> $UP"
  mkdir -p "$ROOT/upstream"
  git clone --filter=blob:none "$UP_URL" "$UP"
fi

echo "[sync] upstream HEAD: $(git -C "$UP" log -1 --format='%h %ad %s' --date=short)"
echo "[sync] latest upstream release (game version the translation targets):"
curl -fsS https://api.github.com/repos/Teyliu/PVZF-Translation/releases/latest \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print('  ', r['tag_name'], r['published_at'][:10], r['name'])" \
  || echo "   (could not reach GitHub API)"
