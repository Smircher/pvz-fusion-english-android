# Build tools

Reference scripts used to produce the English APK. They are provided for
transparency and reproducibility. **They are not needed to *play*** — just download
the finished APK from Releases.

## What you need to reproduce
- **Python 3** with `UnityPy` and `Pillow`:  `pip install UnityPy pillow`
- **Java 8+** (to run uber-apk-signer)
- **Android platform-tools** (`adb`, optional `zipalign`)
- [`uber-apk-signer.jar`](https://github.com/patrickfav/uber-apk-signer/releases)
- The **original Chinese APK** `pvzrh3.8.1.apk` (from the game's official channels)
- The **PC translation folder** `PvZ_Fusion_Translator/` (from
  https://github.com/Teyliu/PVZF-Translation)

> The original APK and the PC translation are **not** included in this repo — they
> belong to their creators. Bring your own copies and place them next to the scripts
> (see the path constants near the top of each script and edit them for your setup).

## Scripts
| File | Purpose |
|---|---|
| `repack.py` | Rebuild an APK from the original, replacing entries, keeping 4-byte alignment; strips old signatures for re-signing. |
| `build_apk.py` | Assemble the final APK: swap in the patched bundle + metadata **and bump `unity_app_guid`** so over-the-top updates (`install -r`) refresh the English text without a save-wiping clean install. |
| `patch_bundle_v2.py` | Main asset patcher: almanac merge (+ font-size wrap + the 9 extra plants), UI string splice into MonoBehaviours, English texture swap. Run with `--textures` for the full build. |
| `patch_metadata_v2.py` | Rebuild-based IL2CPP `global-metadata.dat` string-literal patcher (allows English of any length): HUD, buffs/modifiers, messages. |
| `scan_leftover_cjk.py` | Audit: lists every Chinese string still left in the patched bundle + metadata (`work/leftover/*.json`); its gaps were translated into `translations/leftover_en.json`. |
| `test_patch_helpers.py` | Self-check for the regex / on-screen-text helpers (`python test_patch_helpers.py` prints `ok`). |
| `patch_metadata.py` | Older safe in-place metadata patcher (only same-or-shorter English). Kept for reference. |
| `patch_bundle_full.py`, `patch_bundle_phase1.py`, `patch_bundle_spike.py` | Earlier iterations, kept for history. |
| `build.sh` | Repack + sign helper (legacy: points at an old `scripts/` layout). |
| `config.py` | Shared paths (APK, translation, work dir); each overridable by env var (`PVZ_APK`, `PVZ_MOD`, …). |
| `update_and_build.sh` | **One command:** sync, find the newest Chinese Android APK listed in the upstream README, resolve the matching translation (main or release tag), download, build. `--check`, `--version X`, `--no-build`, `--force`. |
| `fetch_sources.py` | Used by the above: parses the upstream download table, resolves the translation ref, downloads the APK (MEGA built in via pycryptodome / Google Drive via gdown) to `input/`. |
| `test_install.sh` | Install the newest build on BlueStacks/a device (keeps the save; `--clean` for a key change), launch, screenshot + crash log to `work/test/`. |
| `sync.sh` | `git pull` this repo + clone/pull the upstream PVZF-Translation into `upstream/`. |
| `build_release.sh` | One-command build: original APK in `input/` → `output/PvZ-Fusion-<ver>-English.apk` (deps, patch, assemble, sign). |

## One-command flow
```bash
bash tools/update_and_build.sh          # pull, download newest APK + matching translation, build
bash tools/update_and_build.sh --check  # just report what would be built
```
Or step by step: `bash tools/sync.sh`, put the original APK in `input/`, then `bash tools/build_release.sh`.

## Rough flow (manual)
```bash
# 1) translate the asset bundle (with English menu textures)
python patch_bundle_v2.py --textures        # -> work/data.unity3d.v2

# 2) translate the code string-literals
python patch_metadata_v2.py global-metadata.orig.dat global-metadata.v2.dat

# 3) assemble the APK (swaps in bundle + metadata AND bumps unity_app_guid), then sign
python build_apk.py                          # -> unsigned.apk
java -jar uber-apk-signer.jar -a unsigned.apk --skipZipAlign -o out/

# 4) install over the top — keeps the save; the new unity_app_guid makes the game
#    re-extract the English metadata by itself on next launch
adb install -r out/unsigned-signed.apk
```

Note: because `build_apk.py` changes `unity_app_guid` each release, `adb install -r`
now refreshes the code-string translations **without** a clean install — the game
extracts `global-metadata.dat` to `files/il2cpp/` and re-extracts it whenever the APK's
`unity_app_guid` differs from the cached `il2cpp/unity.ver`, so player saves survive
updates (verified on device). `data.unity3d` is read straight from the APK, so
asset/texture changes always apply on `install -r` too. (Sign with the **same key**
every release; a key change is the one thing that still forces a save-wiping uninstall.)
