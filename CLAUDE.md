# CLAUDE.md

## What this repo is
An unofficial **English Android build of *Plants vs. Zombies: Fusion*** (植物大战僵尸融合版),
currently v4.0.5.2. The original Chinese APK is **statically patched** with the community
PC translation (no root, no mod loader). The repo holds only the build scripts (`tools/`),
~1,300+ extra English strings this build adds (`translations/`), and docs. The finished APK
ships through **GitHub Releases** (`Smircher/pvz-fusion-english-android`), never through git.

## README summaries
- **README.md**: what it is, install steps (Android 8+, arm64-v8a, uninstall other-key
  builds first), what's translated (almanac, mechanics/modifiers, menus + English textures,
  HUD, Odyssey content), known limits (a little Chinese left; the original font is kept
  because swapping fonts broke rendering), credits, legal/security notes, a pipeline overview.
- **tools/README.md**: requirements (Python 3 + UnityPy + Pillow, Java 8+, uber-apk-signer,
  adb), what each script does, the manual build flow, and why `unity_app_guid` is bumped.
- **CREDITS.md**: all English text/textures/fonts come from **PVZF-Translation**
  (github.com/Teyliu/PVZF-Translation). Only the Android packaging and `translations/` are original here.
- **docs/INSTALL.md / UPDATE.md / MIGRATION.md**: phone install; in-place updates keep the
  save (`/sdcard/Android/data/com.LanPiaoPiao.PlantsVsZombiesRH/files/playerData.json`);
  how to back up and restore the save when the signing key changes.

## Automated workflow
When asked to **update / pull / build / make the APK**, run (in the background, it takes a while):

```bash
bash tools/update_and_build.sh            # newest version: pull, download, build
bash tools/update_and_build.sh --check    # report only: version, translation ref, build needed?
bash tools/update_and_build.sh --version 3.9 [--no-build] [--force]
```

What it does:
1. `tools/sync.sh`: fast-forwards this repo, and partial-clones or pulls the upstream
   translation into `upstream/PVZF-Translation/` (gitignored; full history + tags).
2. `tools/fetch_sources.py`: reads the upstream README's download table. The
   **"Chinese X | Android"** rows hold the Google Drive and MEGA links for the original APK,
   and it picks the newest X. The matching translation is `origin/main` if its
   `CURRENT_GAME_VER` targets X (e.g. `4.0.5` matches `4.0.5.2`). Otherwise it's the newest
   matching release tag, checked out as a worktree at `upstream/PVZF-Translation@<tag>`.
   The APK downloads to `input/pvzrh<X>.apk` from the mirrors in table order: MEGA (built in, via pycryptodome), then Google Drive (gdown). Drive often hits "too many downloads" quota errors.
3. Skips the build if `output/PvZ-Fusion-<X>-English.apk.src` shows the APK was already
   built from the same translation ref and repo commit. Otherwise it runs `tools/build_release.sh`.
4. `tools/build_release.sh`: installs the Python deps into `.venv`, downloads
   `uber-apk-signer.jar` if missing, then runs: self-test → extract metadata →
   `patch_bundle_v2.py --textures` (slow, ASTC encode) → `patch_metadata_v2.py` →
   `build_apk.py` → sign → `output/PvZ-Fusion-<X>-English.apk`. Use `NO_TEXTURES=1` for a
   quick text-only test build.

If the README table format changes or a download fails, the script exits with the mirror
links. Ask the user to place the APK in `input/` by hand.

Afterwards (optional): `.venv/bin/python tools/scan_leftover_cjk.py` writes any remaining
Chinese strings to `work/leftover/*.json`. Add translations for them to
`translations/leftover_en.json`, or to `overrides.json` for top-priority and overflow fixes.

**Report** the output path, size, and signing-cert SHA-256. Don't commit, push, create a
GitHub release, or `adb install` unless the user asks.

Paths live in `tools/config.py`. Each can be overridden by env var: `PVZ_APK`, `PVZ_MOD`,
`PVZ_EN`, `PVZ_TRANS`, `PVZ_WORK`. The Python scripts import `config` from their own
directory, so run them as `python tools/<script>.py`.

## Critical invariants
- **Signing key must stay the same across releases.** A new key forces users to uninstall,
  which wipes their save. This repo is a fork of `Heagon/pvz-fusion-english-android`.
  Heagon's releases (v3.8.1, v3.9) are signed with Heagon's own private key
  (`CN=PvZ Fusion English, OU=Heagon`, cert SHA-256 `02:40:76:08:…:39:F2`), and that key
  isn't available here. So builds from this fork **cannot** update over Heagon's APKs:
  players switching over must back up and restore their save (docs/MIGRATION.md).
  **This fork's release key:** `~/.config/pvz-fusion-en/release.p12` (alias `pvz-en`,
  created 2026-10-06, cert SHA-256 `83:CA:27:0E:…:CE:E3`). Its password is in
  `~/.config/pvz-fusion-en/signing.env`, which both build scripts source automatically.
  Every release must show that cert. If the env file is missing, the build falls back to
  uber-apk-signer's public debug key (`1e08a903…5953`) and prints a warning. That's for
  test builds only, never a release. Never commit, print, or copy the keystore or its password.
- Upstream labels hotfixes with an extra version part (table `4.0.5.2`, APK `versionName`
  `4.0.5`). Prefix matches are expected, not an error.
- **`build_apk.py` must bump `unity_app_guid`.** It sets it to md5(metadata) shaped as a
  UUID. That bump is what makes the game re-extract the metadata after `install -r`.
  `boot.config` `build-guid` does **not** gate the cache (verified on a device).
- **`repack.py` 4-byte-aligns STORED entries.** Android 30+ and Unity's mmap of `data.unity3d`
  need it, so `--skipZipAlign` is used when signing.
- **Never commit or re-host** APKs, `*.unity3d`, `global-metadata*.dat`, the PC translation,
  fonts, or `*.jar`. `.gitignore` covers these, plus `upstream/`, `input/`, `work/`, `output/`.
- `translations/changelog_cn.txt` is a byte-exact dictionary key (CRLF, `-text` in
  `.gitattributes`). Never re-encode it or change its line endings.

## Code map
- `tools/patch_bundle_v2.py`: main asset patcher. It builds a master CN→EN dict (upstream
  `Dumps/` CN + `Localization/English/` EN + `translations/*.json`), merges the almanac
  (font size 12), splices MonoBehaviour strings length-safely, applies upstream
  `translation_regexs.json`, and swaps textures with `--textures`. Output: `work/data.unity3d.v2`.
- `tools/patch_metadata_v2.py <in> <out>`: rebuilds the IL2CPP (v31) string-literal blob so
  English of any length fits. It reuses `load_regexes`/`regex_tr` from `patch_bundle_v2`.
- Translation precedence: `build_master()` uses `setdefault`, so the **first** source wins.
  Upstream dicts come first. `supplement.json` and `detail_titles_en.json` only fill gaps.
  Only the hard-coded entries in `main()` and then `translations/overrides.json` **overwrite**,
  so put a fix for a wrong upstream string in `overrides.json`. `leftover_en.json` only
  fills strings that are still Chinese.
- `tools/test_patch_helpers.py`: self-check (`cd tools && python test_patch_helpers.py`
  prints `ok`). Run it after editing the helpers.
- Legacy, kept for history (don't use): `patch_metadata.py`, `patch_bundle_{full,phase1,spike}.py`,
  and `build.sh` (it points at an old `scripts/` layout).
- `tools/update.ps1`: Windows/PowerShell updater that backs up the save, runs `adb install -r`,
  and restores the save on failure.

## Testing a build (before any push/release)
`[SERIAL=<device>] bash tools/test_install.sh [--clean] [apk]` installs the newest
`output/*.apk`, backs up and keeps the save (`playerData.json` + `LevelData`), launches the
game, waits for its window, and saves `screen.png` and `crash.log` to `work/test/<timestamp>/`.
Look at the screenshot to check the text is in English. `--clean` handles a copy signed with a
different key: it also keeps `previous.apk`, then uninstalls, installs and restores the save.
**Ask the user before using `--clean`**, because it uninstalls their app.

adb: `tools/platform-tools/adb.exe` (Windows platform-tools 37, gitignored; download it again
from dl.google.com if missing). WSL's own adb can't reach USB or the LAN, and BlueStacks'
`HD-Adb.exe` (1.0.36) is too old for wireless pairing.
- **BlueStacks** (default `SERIAL=127.0.0.1:5555`): instance `Pie64`, Android 9, arm64 OK.
  It needs **Settings → Advanced → Android Debug Bridge** on.
- **User's phone**: Galaxy S25 Ultra, Android 16, USB serial `R5CY93N8YZJ`.
- **User's tablet**: Galaxy Tab S10 FE (SM-X620), Android 16, 2880x1800, USB serial `R5GL40CTLCB`.
- Both Samsung devices run the 2026-10-06 build signed with the release key. Samsung **Auto
  Blocker** (Settings → Security and privacy) blocks adb and sideloading, so the user has to
  turn it off for each install or update. The first launch shows a black screen for ~15–30 s
  while the bundle loads.

## Environment notes (this machine: WSL2)
- Android SDK at `~/android_sdk` (adb in `platform-tools/`, aapt/apksigner in `build-tools/`).
  To install on a USB phone from WSL, adb needs usbipd. Using Windows adb or `tools/update.ps1` is easier.
- Java 11 via sdkman. The project venv is at `.venv/` (Python 3.11).

## Releasing (only when asked)
Update the version in README.md (title, APK filename) and the docs, commit, push, then
upload the APK as a GitHub Release asset (`gh` is not installed here).
Recent commits follow the pattern "Release X: update README + sync reference tools" or
"Sync tools: …".
