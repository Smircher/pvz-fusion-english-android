#!/usr/bin/env bash
# End-to-end build: original Chinese APK + upstream translation -> signed English APK.
#
# Usage: bash tools/build_release.sh
# Env overrides:
#   PVZ_APK=path.apk      original Chinese APK (default: newest input/*.apk)
#   VERSION=4.0.5.2       version label for the output name (default: read from the APK)
#   NO_TEXTURES=1         skip the slow English texture swap (quick text-only test build)
#   PVZ_KEYSTORE=... PVZ_KS_ALIAS=... PVZ_KS_PASS=... PVZ_KEY_PASS=...
#                         sign with this keystore. Default: loaded from $PVZ_SIGNING_ENV
#                         (~/.config/pvz-fusion-en/signing.env) if it exists, else
#                         uber-apk-signer's public debug key (test builds only).
#   SDK=~/android_sdk     Android SDK (for aapt/apksigner, only used for version + cert print)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$ROOT/tools"
WORK="${PVZ_WORK:-$ROOT/work}"
OUTDIR="$ROOT/output"
SDK="${SDK:-$HOME/android_sdk}"
SIGNER="$T/uber-apk-signer.jar"
SIGNER_URL="https://github.com/patrickfav/uber-apk-signer/releases/download/v1.3.0/uber-apk-signer-1.3.0.jar"
PY="$ROOT/.venv/bin/python"
mkdir -p "$WORK" "$OUTDIR"
SIGNING_ENV="${PVZ_SIGNING_ENV:-$HOME/.config/pvz-fusion-en/signing.env}"
if [ -z "${PVZ_KEYSTORE:-}" ] && [ -f "$SIGNING_ENV" ]; then source "$SIGNING_ENV"; fi

# --- inputs ---
APK="${PVZ_APK:-$(ls -t "$ROOT"/input/*.apk 2>/dev/null | head -1 || true)}"
[ -n "$APK" ] && [ -f "$APK" ] || { echo "ERROR: no original Chinese APK. Put it in input/ or set PVZ_APK." >&2; exit 1; }
export PVZ_APK="$APK"
MOD="${PVZ_MOD:-$ROOT/upstream/PVZF-Translation/PvZ_Fusion_Translator}"
[ -d "$MOD/Dumps" ] || { echo "ERROR: translation not found at $MOD. Run: bash tools/sync.sh" >&2; exit 1; }
command -v java >/dev/null || { echo "ERROR: java not on PATH" >&2; exit 1; }

# --- toolchain ---
if [ ! -x "$PY" ]; then python3 -m venv "$ROOT/.venv"; fi
"$PY" -c "import UnityPy, PIL" 2>/dev/null || "$PY" -m pip install -q UnityPy pillow
if [ ! -f "$SIGNER" ]; then echo "[build] downloading uber-apk-signer"; curl -fsSL -o "$SIGNER" "$SIGNER_URL"; fi
AAPT="$(ls -d "$SDK"/build-tools/*/ 2>/dev/null | sort -V | tail -1)aapt"
APKSIGNER="$(ls -d "$SDK"/build-tools/*/ 2>/dev/null | sort -V | tail -1)apksigner"

APK_VER=""
if [ -x "$AAPT" ]; then
  APK_VER="$("$AAPT" dump badging "$APK" 2>/dev/null | sed -n "s/.*versionName='\([^']*\)'.*/\1/p" | head -1)"
fi
# Upstream labels hotfixes with an extra part (4.0.5.2) the APK doesn't carry (4.0.5).
if [ -n "${VERSION:-}" ] && [ -n "$APK_VER" ] && [ "$VERSION" != "$APK_VER" ] && [ "${VERSION#"$APK_VER".}" = "$VERSION" ]; then
  echo "[build] WARNING: expected version $VERSION but the APK says versionName=$APK_VER" >&2
fi
VERSION="${VERSION:-$APK_VER}"
VERSION="${VERSION:-unknown}"
echo "[build] source APK: $APK (version $VERSION)"
echo "[build] translation: $MOD @ $(git -C "$MOD/.." log -1 --format=%h 2>/dev/null || echo '?')"

# --- pipeline ---
echo "[build] 0/5 self-test"
(cd "$T" && "$PY" test_patch_helpers.py)

echo "[build] 1/5 extract global-metadata.dat"
"$PY" - "$APK" "$WORK/global-metadata.orig.dat" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    open(sys.argv[2], "wb").write(z.read("assets/bin/Data/Managed/Metadata/global-metadata.dat"))
EOF

echo "[build] 2/5 patch asset bundle"
if [ -n "${NO_TEXTURES:-}" ]; then "$PY" "$T/patch_bundle_v2.py"; else "$PY" "$T/patch_bundle_v2.py" --textures; fi

echo "[build] 3/5 patch IL2CPP metadata"
"$PY" "$T/patch_metadata_v2.py" "$WORK/global-metadata.orig.dat" "$WORK/global-metadata.v2.dat"

echo "[build] 4/5 assemble APK (bumps unity_app_guid)"
"$PY" "$T/build_apk.py" "$WORK/unsigned.apk"

echo "[build] 5/5 sign"
SIGN_ARGS=(-a "$WORK/unsigned.apk" --skipZipAlign -o "$WORK/signed")
if [ -n "${PVZ_KEYSTORE:-}" ]; then
  SIGN_ARGS+=(--ks "$PVZ_KEYSTORE" --ksAlias "${PVZ_KS_ALIAS:?}" --ksPass "${PVZ_KS_PASS:?}" --ksKeyPass "${PVZ_KEY_PASS:-$PVZ_KS_PASS}")
fi
if [ -z "${PVZ_KEYSTORE:-}" ]; then
  echo "[build] WARNING: no release keystore - signing with the public debug key (test build only)" >&2
fi
rm -rf "$WORK/signed"
java -jar "$SIGNER" "${SIGN_ARGS[@]}"
FINAL="$OUTDIR/PvZ-Fusion-$VERSION-English.apk"
mv "$(ls "$WORK"/signed/*.apk | head -1)" "$FINAL"

echo "[build] done: $FINAL ($(du -h "$FINAL" | cut -f1))"
if [ -x "$APKSIGNER" ]; then
  echo "[build] signing cert (must match the previous release, or users lose saves on update):"
  "$APKSIGNER" verify --print-certs "$FINAL" | grep -i "SHA-256" || true
fi
