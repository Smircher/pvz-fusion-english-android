#!/usr/bin/env bash
# Install a built APK on a test device (BlueStacks by default), launch it, screenshot it.
#
# Usage: bash tools/test_install.sh [--clean] [apk]
#   apk       default: newest output/*.apk
#   --clean   if the installed copy has a different signing key: back up the save,
#             uninstall, install, restore the save (like tools/update.ps1 -Clean)
# Env: ADB=path/to/adb(.exe)   default: tools/platform-tools/adb.exe, BlueStacks HD-Adb.exe,
#                              else adb.exe/adb on PATH
#      SERIAL=127.0.0.1:5555   device: BlueStacks (enable Settings > Advanced > ADB), or a USB
#                              serial from `adb devices` (Samsung: turn off Auto Blocker first)
#      WAIT=120                max seconds to wait for the game window before the screenshot
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="com.LanPiaoPiao.PlantsVsZombiesRH"
FILES="/sdcard/Android/data/$PKG/files"
SAVE="$FILES/playerData.json"
SERIAL="${SERIAL:-127.0.0.1:5555}"
WAIT="${WAIT:-120}"
CLEAN=""; APK=""
for a in "$@"; do
  case "$a" in --clean) CLEAN=1 ;; -h|--help) sed -n 2,13p "$0"; exit 0 ;; *) APK="$a" ;; esac
done
APK="${APK:-$(ls -t "$ROOT"/output/*.apk 2>/dev/null | head -1 || true)}"
[ -f "$APK" ] || { echo "ERROR: no APK found (build one first)" >&2; exit 1; }

if [ -z "${ADB:-}" ]; then
  for c in "$ROOT/tools/platform-tools/adb.exe" "/mnt/c/Program Files/BlueStacks_nxt/HD-Adb.exe" "$(command -v adb.exe || true)" "$(command -v adb || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADB="$c"; break; }
  done
fi
[ -n "${ADB:-}" ] || { echo "ERROR: no adb found; set ADB=" >&2; exit 1; }
# A Windows adb.exe needs Windows paths for files.
hostpath() { case "$ADB" in *.exe) wslpath -w "$1" ;; *) echo "$1" ;; esac; }
adb() { "$ADB" -s "$SERIAL" "$@" | tr -d '\r'; }

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/work/test/$TS"; mkdir -p "$OUT"
echo "[test] adb: $ADB -> $SERIAL"
case "$SERIAL" in *:*) "$ADB" connect "$SERIAL" | tr -d '\r' ;; esac
[ "$(adb get-state 2>/dev/null)" = device ] || {
  echo "ERROR: $SERIAL not reachable. In BlueStacks: Settings > Advanced > Android Debug Bridge ON." >&2; exit 1; }
echo "[test] device: Android $(adb shell getprop ro.build.version.release), abi $(adb shell getprop ro.product.cpu.abilist)"

HAVE_SAVE=""
if adb shell "[ -f $SAVE ] && echo y" | grep -q y; then
  "$ADB" -s "$SERIAL" pull "$SAVE" "$(hostpath "$OUT/playerData.json")" >/dev/null 2>&1 && HAVE_SAVE=1
  "$ADB" -s "$SERIAL" pull "$FILES/LevelData" "$(hostpath "$OUT")" >/dev/null 2>&1 || true
  echo "[test] save backed up -> $OUT/ (playerData.json$([ -d "$OUT/LevelData" ] && echo ' + LevelData'))"
fi

echo "[test] installing $(basename "$APK") ($(du -h "$APK" | cut -f1)) over the top"
if ! RES="$("$ADB" -s "$SERIAL" install -r "$(hostpath "$APK")" 2>&1 | tr -d '\r')"; then :; fi
echo "$RES" | tail -2
if ! echo "$RES" | grep -q Success; then
  if echo "$RES" | grep -qE "UPDATE_INCOMPATIBLE|signatures do not match"; then
    [ -n "$CLEAN" ] || { echo "ERROR: installed copy is signed with a different key. Re-run with --clean (save is backed up first)." >&2; exit 1; }
    echo "[test] --clean: uninstall + install"
    adb shell pm path "$PKG" | sed -n 's/^package://p' | head -1 | while read -r p; do
      "$ADB" -s "$SERIAL" pull "$p" "$(hostpath "$OUT/previous.apk")" >/dev/null && echo "[test] previous APK kept -> $OUT/previous.apk"
    done
    adb uninstall "$PKG"
    "$ADB" -s "$SERIAL" install "$(hostpath "$APK")" | tr -d '\r' | tail -1
  else
    echo "ERROR: install failed" >&2; exit 1
  fi
  if [ -n "$HAVE_SAVE" ]; then
    adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 10
    adb shell am force-stop "$PKG"
    adb shell mkdir -p "$FILES"
    "$ADB" -s "$SERIAL" push "$(hostpath "$OUT/playerData.json")" "$SAVE" >/dev/null
    if [ -d "$OUT/LevelData" ]; then "$ADB" -s "$SERIAL" push "$(hostpath "$OUT/LevelData")" "$FILES/" >/dev/null; fi
    echo "[test] save restored"
  fi
fi

echo "[test] launching (waiting up to ${WAIT}s for the game window)"
adb logcat -c || true
adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true   # screen may have timed out
ACT="$(adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$PKG" | tail -1)"
adb shell am start -n "$ACT" >/dev/null 2>&1
for _ in $(seq 1 "$WAIT"); do
  adb shell dumpsys window | grep -q "mCurrentFocus.*$PKG" && break
  sleep 1
done
sleep 15   # first frames after focus are black while the asset bundle loads
"$ADB" -s "$SERIAL" exec-out screencap -p > "$OUT/screen.png"
echo "[test] screenshot -> $OUT/screen.png"
if adb shell pidof "$PKG" >/dev/null; then echo "[test] game is running"; else echo "[test] WARNING: game process not running" >&2; fi
adb logcat -d -b crash > "$OUT/crash.log" || true
if [ -s "$OUT/crash.log" ]; then echo "[test] WARNING: crash log not empty -> $OUT/crash.log" >&2; else echo "[test] no crashes logged"; fi
