#!/usr/bin/env bash
# One command: pull everything, find the newest game APK + matching translation,
# download them, and build the English APK.
#
# Usage: bash tools/update_and_build.sh [--version X] [--check] [--no-build] [--force]
#   --version X   build a specific game version (default: newest Android APK upstream lists)
#   --check       only report what would be built; download and build nothing
#   --no-build    download inputs but stop before building
#   --force       rebuild even if the existing output was built from the same sources
# Any env var build_release.sh understands (NO_TEXTURES, PVZ_KEYSTORE, ...) passes through.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/.venv/bin/python"
FETCH_ARGS=(); CHECK=""; BUILD=1; FORCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) FETCH_ARGS+=(--version "$2"); shift 2 ;;
    --check) CHECK=1; FETCH_ARGS+=(--check); shift ;;
    --no-build) BUILD=""; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n 2,11p "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

bash "$ROOT/tools/sync.sh"

if [ ! -x "$PY" ]; then python3 -m venv "$ROOT/.venv"; fi
"$PY" -c "import gdown, Crypto" 2>/dev/null || "$PY" -m pip install -q gdown pycryptodome

ENV_LINES="$("$PY" "$ROOT/tools/fetch_sources.py" "${FETCH_ARGS[@]}")"
eval "$ENV_LINES"
export PVZ_APK PVZ_MOD VERSION

PUBLISHED="$(sed -n '1s/.*Fusion \([0-9.]*\).*/\1/p' "$ROOT/README.md")"
FINAL="$ROOT/output/PvZ-Fusion-$VERSION-English.apk"
echo "[update] game version : $VERSION (this repo's README is on ${PUBLISHED:-?})"
echo "[update] translation  : $UPSTREAM_REF"
echo "[update] source APK   : $PVZ_APK"
if [ "$VERSION" != "$PUBLISHED" ]; then
  echo "[update] NEW VERSION vs. the published README - update README/docs when releasing."
fi

# The .src stamp records what an APK was built from; rebuild when any input changed.
SIGNING_ENV="${PVZ_SIGNING_ENV:-$HOME/.config/pvz-fusion-en/signing.env}"
if [ -z "${PVZ_KEYSTORE:-}" ] && [ -f "$SIGNING_ENV" ]; then source "$SIGNING_ENV"; fi
STAMP="$FINAL.src"
SRC="translation=$UPSTREAM_REF repo=$(git -C "$ROOT" rev-parse --short HEAD)$(git -C "$ROOT" diff --quiet HEAD -- tools translations || echo '+dirty') key=${PVZ_KEYSTORE:-debug}"
if [ -f "$FINAL" ] && [ -z "$FORCE" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$SRC" ]; then
  echo "[update] up to date: $FINAL was built from the same sources ($SRC). Use --force to rebuild."
  exit 0
fi
if [ -n "$CHECK" ]; then echo "[update] a build is needed ($SRC)"; exit 0; fi
if [ -z "$BUILD" ]; then exit 0; fi

bash "$ROOT/tools/build_release.sh"
echo "$SRC" > "$STAMP"
